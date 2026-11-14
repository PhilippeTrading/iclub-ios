//
//  DayAvailabilityStore.swift
//  iClub
//
//  Réservations et blocages du club pour *un* jour. Le magasin ne garde que les
//  données brutes : la grille est recalculée par `AvailabilityEngine` à partir
//  des terrains du `ClubCatalog`. Un terrain ajouté ou désactivé par l'admin est
//  donc pris en compte sans invalidation manuelle ici.
//
//  Le périmètre est (club, jour), pas (club, jour, sport) : une seule requête
//  couvre les trois sports, et changer de sport n'entraîne aucun aller-retour.
//
//  Place dans l'application
//    Créé par `BookingView` (racine du tunnel de réservation) et partagé avec
//    `CourtPickerView` ; la création d'une partie ouverte
//    (`OpenGameCreateFlow`) a ses propres instances.
//
//  Sources
//    `PlanningService.loadReservations` (table `reservations`, statut
//    `confirmee`, club et jour donnés) et `PlanningService.loadSlotOverrides`
//    (table `slot_overrides`, blocages posés par le club : entretien, cours,
//    tournoi...). La sécurité au niveau des lignes (RLS) n'ouvre ces tables
//    qu'aux membres du club.
//
//  Fil d'exécution et erreurs
//    Classe sur l'acteur principal (réglage par défaut du projet). Un échec de
//    lecture passe la phase à `.failed` : l'écran montre une erreur plutôt que
//    des créneaux peut-être faux.
//
//  Points d'attention
//    Attention : `AvailabilityEngine` ne rend indisponible que le créneau qui
//    commence exactement à l'heure de début d'un blocage ou d'une réservation.
//    Un blocage plus long qu'un créneau (un cours de 18 h à 20 h ne crée qu'une
//    ligne `slot_overrides`) laisse les créneaux suivants affichés libres,
//    alors que le planning web les grise (fonction `couvre` de
//    src/lib/data/planningGrid.ts) ; et la base n'empêche pas de les réserver
//    (l'index unique `reservations_no_double_booking` ne porte que sur l'heure
//    de début).
//

import Foundation
import Observation
import Supabase

/// Données brutes de disponibilité d'un jour pour tout le club, tenues à jour
/// en temps réel.
@Observable
final class DayAvailabilityStore {

    /// Avancement de la lecture du jour courant.
    enum Phase: Equatable {
        /// Aucun jour demandé, ou jour qui vient de changer.
        case idle
        /// Lecture en cours, sans données valides pour ce jour.
        case loading
        /// Données du jour chargées.
        case ready
        /// Lecture impossible ; message prêt à afficher.
        case failed(String)
    }

    /// Avancement, observé par les écrans.
    private(set) var phase: Phase = .idle
    /// Réservations confirmées du club pour le jour (terrain et heure de début).
    private(set) var reservations: [ReservationRow] = []
    /// Blocages du club pour le jour (terrain, heure de début, raison).
    private(set) var overrides: [SlotOverrideRow] = []

    /// Club du jour chargé.
    private var clubId: UUID?
    /// Jour chargé (fuseau de l'appareil).
    private var date: Date?
    /// Relecture différée en attente (voir `scheduleReload`).
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    // MARK: - Cycle de vie

    /// Charge le jour demandé puis reste à l'écoute jusqu'à annulation de la
    /// tâche appelante. À utiliser depuis un `.task(id:)`, qui gère le démontage.
    ///
    /// - Parameters:
    ///   - clubId: club du compte connecté.
    ///   - date: jour à afficher ; seule la date compte, pas l'heure.
    func activate(clubId: UUID, date: Date) async {
        if self.clubId != clubId || self.date.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) ?? true {
            // Changement de jour : les données précédentes ne veulent plus rien
            // dire, on repart d'un écran de chargement propre.
            reservations = []
            overrides = []
            phase = .idle
        }

        self.clubId = clubId
        self.date = date

        await reload()
        await observeChanges(clubId: clubId)
    }

    /// Relit les réservations et les blocages du jour courant, en parallèle.
    /// Sans effet tant qu'aucun jour n'a été demandé.
    func reload() async {
        guard let clubId, let date else { return }
        // Une relecture en temps réel ne repasse pas par `.loading` : la liste
        // affichée reste en place jusqu'à la réponse.
        if phase != .ready { phase = .loading }

        do {
            async let reservationsTask = PlanningService.loadReservations(clubId: clubId, date: date)
            async let overridesTask = PlanningService.loadSlotOverrides(clubId: clubId, date: date)

            reservations = try await reservationsTask
            overrides = try await overridesTask
            phase = .ready
        } catch {
            // Afficher des créneaux libres alors qu'on n'a pas pu lire les
            // réservations serait pire que de ne rien afficher : on échoue franchement.
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Grille

    /// Grille du sport pour le jour courant, recalculée à la demande. Le coût
    /// est négligeable (quelques centaines d'itérations) et cela garantit que
    /// l'affichage suit à la fois le magasin et le catalogue de terrains.
    ///
    /// Seuls les terrains réservables par la personne entrent dans la grille
    /// (`ClubCatalog.courts(for:)` écarte les terrains qui lui sont fermés) ;
    /// pour aujourd'hui, les créneaux déjà commencés sont retirés.
    ///
    /// - Parameters:
    ///   - sport: sport affiché.
    ///   - catalog: catalogue du club (terrains, horaires d'ouverture).
    /// - Returns: un `SlotAvailability` par créneau, trié par heure, avec l'état
    ///   de chaque terrain ; vide tant qu'aucun jour n'est chargé.
    func slots(for sport: Sport, catalog: ClubCatalog) -> [SlotAvailability] {
        guard let date else { return [] }

        return AvailabilityEngine.slots(
            courts: catalog.courts(for: sport),
            settings: catalog.settings(for: sport),
            reservations: reservations,
            overrides: overrides,
            date: date
        )
    }

    // MARK: - Temps réel

    /// `reservations` et `slot_overrides` sont suivies pour que la liste reste
    /// juste pendant que l'écran est ouvert : quelqu'un peut confirmer le même
    /// créneau à la même seconde. Les terrains sont suivis par `ClubCatalog`.
    ///
    /// - Parameter clubId: club suivi, qui sert à nommer le canal.
    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("booking-availability-\(clubId.uuidString)")
        let reservationChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "reservations")
        let overrideChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "slot_overrides")

        // Un abonnement qui échoue ne doit pas casser l'écran : la liste reste
        // exacte au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Aucun filtre n'est posé sur les événements eux-mêmes : la RLS ne
        // transmet que les changements des clubs du membre, et chacun relance
        // une lecture limitée au club et au jour affichés. Le volume est
        // négligeable, et cela évite de dépendre de la syntaxe de filtre du
        // serveur Realtime.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await _ in reservationChanges { await self?.scheduleReload() }
            }
            group.addTask { [weak self] in
                for await _ in overrideChanges { await self?.scheduleReload() }
            }
        }
    }

    /// Une confirmation côté web émet souvent plusieurs événements d'affilée.
    /// On les regroupe derrière un court délai plutôt que de relire la base à
    /// chacun.
    /// Chaque événement annule la relecture en attente et relance le délai de
    /// 250 ms.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
