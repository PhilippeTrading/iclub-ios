//
//  HomeStore.swift
//  iClub
//
//  Données de l'accueil : prochaine réservation, cours, annonces, crédits.
//
//  Un seul magasin pour tout l'écran, et un seul abonnement temps réel : un
//  autre membre qui rejoint la réservation, un admin qui publie une annonce ou
//  ajuste une adhésion doivent se voir sans délai perceptible.
//
//  Rôle
//    Magasin observable de `HomeView`, créé par la vue et vivant avec elle. Il
//    charge les quatre sections de l'accueil et les tient à jour.
//
//  Sources
//    - prochaine réservation : `ReservationService.loadMine` (tables
//      `reservations` et `reservation_participants`), puis photos des joueurs
//      par la fonction SQL `get_club_roster_info` (`ClubDirectoryService`) ;
//    - cours : `ClubContentService.activities` (table `activites`, les 3
//      premiers dans l'ordre de création) ;
//    - annonces : `ClubContentService.announcements` (table `annonces`, les 2
//      plus récentes encore actives) ;
//    - crédits invités : `GuestCreditService.balance` (tables
//      `guest_credit_allowances` et `reservations`), recalculés à chaque
//      lecture, jamais stockés.
//    Toutes ces lectures passent par le client Supabase de l'utilisateur : la
//    sécurité au niveau des lignes (RLS) limite ce qu'il voit à son club, et à
//    ses propres adhésions et dotations.
//
//  Temps réel
//    Un canal Supabase Realtime écoute `reservations`,
//    `reservation_participants`, `annonces`, `memberships` et
//    `guest_credit_allowances` ; chaque rafale d'événements déclenche une
//    relecture complète, regroupée derrière un délai de 250 ms.
//
//  Fil d'exécution et erreurs
//    Classe isolée sur l'acteur principal (réglage par défaut du projet) : les
//    propriétés observées par la vue n'y sont modifiées que là. Aucune erreur
//    n'est remontée à l'écran : chaque section se replie sur une valeur sûre
//    (rien, ou ce qui était déjà affiché).
//
//  Points d'attention
//    - Attention : `reservation_participants` ne fait pas partie de la
//      publication temps réel de la base (migration 20260923110000, exclue
//      volontairement) ; son flux ne reçoit donc rien, et un joueur qui
//      rejoint une partie n'apparaît qu'à la prochaine relecture déclenchée
//      par une autre table, au retour sur l'écran ou au « tirer pour
//      actualiser ».
//    - Limite connue : `loadMine` lit toutes les réservations du membre,
//      passées comprises, triées de la plus ancienne à la plus récente, puis
//      l'accueil garde la prochaine. Au-delà de la limite de lignes par appel
//      de l'API Supabase (mille par défaut), les plus récentes, donc les
//      réservations à venir, seraient tronquées.
//    - Pour un enfant sélectionné, le profil actif n'a pas de période
//      d'adhésion connue : ses crédits invités sont toujours nuls.
//

import Foundation
import Observation
import Supabase

/// Magasin de l'accueil : prochaine réservation et ses joueurs, cours du club,
/// annonces récentes et solde de crédits invités.
@Observable
final class HomeStore {

    /// Avancement du premier chargement. Il n'y a pas d'état d'erreur : chaque
    /// section gère son propre repli.
    enum Phase: Equatable {
        /// Rien n'a encore été demandé.
        case idle
        /// Premier chargement en cours : la vue montre des squelettes.
        case loading
        /// Au moins un chargement terminé ; les relectures suivantes ne
        /// repassent pas par `.loading`.
        case ready
    }

    /// Avancement du chargement, observé par la vue.
    private(set) var phase: Phase = .idle

    /// Réservation confirmée la plus proche où je figure, créée par moi ou
    /// non, exactement comme dans « Mes réservations ». `nil` s'il n'y en a
    /// aucune à venir.
    private(set) var nextReservation: MyReservation?
    /// Photos des participants de cette réservation.
    /// Indexées par `profiles.id` ; les invités, sans profil, n'y figurent pas.
    private(set) var roster: [UUID: RosterInfoRow] = [:]
    /// Premiers cours et activités du club (au plus `activityLimit`).
    private(set) var activities: [ClubActivity] = []
    /// Annonces actives les plus récentes (au plus `announcementLimit`).
    private(set) var announcements: [Announcement] = []
    /// Solde de crédits invités de la période d'adhésion en cours ; nul sans
    /// adhésion active.
    private(set) var credits: GuestCreditBalance = .none

    /// Profil au nom duquel l'accueil est chargé (le compte connecté ou
    /// l'enfant sélectionné), mémorisé pour les relectures.
    private var profile: SessionProfile?
    /// Relecture différée en attente (voir `scheduleReload`).
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    /// Nombre de cours affichés sur l'accueil.
    static let activityLimit = 3
    /// Nombre d'annonces affichées sur l'accueil.
    static let announcementLimit = 2

    // MARK: - Cycle de vie

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    ///
    /// À appeler depuis un `.task(id:)` de la vue, qui l'annule quand l'écran
    /// disparaît ou que le profil actif change.
    ///
    /// - Parameter profile: profil actif (soi ou un enfant).
    func activate(profile: SessionProfile) async {
        self.profile = profile
        await reload()
        await observeChanges(clubId: profile.clubId)
    }

    /// Relit les quatre sections. Sans effet tant que `activate` n'a pas
    /// fourni de profil.
    func reload() async {
        guard let profile else { return }
        // Squelettes au tout premier chargement seulement : une relecture ne
        // doit pas faire clignoter l'écran.
        if phase == .idle { phase = .loading }

        // Les quatre sections sont indépendantes : elles se chargent en
        // parallèle, et l'échec de l'une ne prive pas des autres.
        async let reservationsTask = loadNextReservation(profile: profile)
        async let activitiesTask = ClubContentService.activities(
            clubId: profile.clubId, limit: Self.activityLimit
        )
        async let announcementsTask = ClubContentService.announcements(
            clubId: profile.clubId, limit: Self.announcementLimit
        )
        // Sans période d'adhésion active, le service rend un solde nul.
        async let creditsTask = GuestCreditService.balance(
            clubId: profile.clubId,
            clubMemberId: profile.clubMemberId,
            profileId: profile.id,
            period: profile.activeMembershipPeriod
        )

        // Publication des résultats, section par section.
        let next = await reservationsTask
        nextReservation = next.reservation
        roster = next.roster
        activities = await activitiesTask
        announcements = await announcementsTask
        credits = await creditsTask

        phase = .ready
    }

    /// Cherche la prochaine réservation du profil et les photos de ses joueurs.
    ///
    /// « Prochaine » : non annulée, dont l'heure de début (fuseau de
    /// l'appareil) n'est pas encore passée, la plus proche dans le temps.
    ///
    /// - Parameter profile: profil dont on cherche les réservations (créées
    ///   par lui ou auxquelles il participe).
    /// - Returns: la réservation (ou `nil`) et les fiches joueurs indexées par
    ///   profil. En cas d'erreur de lecture, les valeurs déjà affichées.
    private func loadNextReservation(
        profile: SessionProfile
    ) async -> (reservation: MyReservation?, roster: [UUID: RosterInfoRow]) {
        do {
            let all = try await ReservationService.loadMine(
                clubId: profile.clubId,
                profileId: profile.id
            )
            let next = all
                .filter { !$0.isCancelled && $0.isUpcoming }
                .min { $0.startsAt < $1.startsAt }

            guard let next else { return (nil, [:]) }

            // Photos et classements des membres inscrits, par la fonction
            // `get_club_roster_info` : la fiche d'un autre membre n'est pas
            // lisible directement. Tolérant : un échec rend un dictionnaire vide.
            let ids = next.participants.compactMap(\.profileId)
            let info = ids.isEmpty ? [:] : await ClubDirectoryService.rosterInfo(profileIds: ids)
            return (next, info)
        } catch {
            // On garde ce qui est déjà affiché plutôt que de vider la carte.
            return (nextReservation, roster)
        }
    }

    // MARK: - Temps réel

    /// Écoute les tables qui changent le contenu de l'accueil, jusqu'à
    /// l'annulation de la tâche appelante ; le canal est alors fermé.
    ///
    /// Aucun filtre par club n'est posé sur les flux : la sécurité au niveau
    /// des lignes ne transmet que les changements que le membre a le droit de
    /// lire.
    ///
    /// - Parameter clubId: club du profil, qui sert à nommer le canal.
    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("home-\(clubId.uuidString)")

        // Cinq tables, un seul canal : les rafales sont regroupées en aval.
        let streams = [
            channel.postgresChange(AnyAction.self, schema: "public", table: "reservations"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "reservation_participants"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "annonces"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "memberships"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "guest_credit_allowances"),
        ]

        // Un abonnement qui échoue ne doit pas casser l'écran : le contenu
        // reste exact au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Un consommateur par flux ; tout événement demande une relecture
        // groupée. Le groupe ne se termine qu'à l'annulation.
        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask { [weak self] in
                    for await _ in stream { await self?.scheduleReload() }
                }
            }
        }
    }

    /// Une seule action côté base émet souvent plusieurs événements. On les
    /// regroupe derrière un court délai plutôt que de tout relire à chacun.
    /// Chaque nouvel événement annule la relecture en attente et relance le
    /// délai de 250 ms.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
