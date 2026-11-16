//
//  OpenGamesStore.swift
//  iClub
//
//  Parties ouvertes du club, tenues à jour en temps réel : une partie peut se
//  remplir pendant qu'on la regarde.
//
//  Le magasin garde *toutes* les parties confirmées, y compris les complètes.
//  La liste les masque, mais la règle « une partie ouverte par jour » doit les
//  compter : un membre engagé dans une partie complète est bel et bien engagé.
//
//  Place dans l'application
//    Créé par `OpenGamesView` (racine de l'onglet « Parties ») et passé au
//    formulaire de création (`OpenGameFormView`) ; le détail d'une partie
//    ouvert depuis une notification s'en sert aussi (`ensureLoaded`).
//
//  Sources
//    - `OpenGameService.loadAll` : lignes de `reservations` du club avec
//      `est_partie_ouverte = true`, statut `confirmee`, à partir d'aujourd'hui,
//      avec leur terrain et leurs participants (`reservation_participants`).
//    - `ClubDirectoryService.rosterInfo` (fonction SQL `get_club_roster_info`)
//      pour les photos, âges et classements des joueurs.
//    La RLS ouvre ces lectures à tout membre du club.
//
//  Fil d'exécution et erreurs
//    Classe sur l'acteur principal (réglage par défaut du projet). Une erreur
//    de lecture n'efface jamais une liste déjà affichée ; elle n'est montrée
//    (`.failed`) que s'il n'y a encore rien à l'écran.
//
//  Points d'attention
//    Attention : `reservation_participants` ne fait pas partie de la
//    publication temps réel de la base (migration 20260923110000). Un joueur
//    qui rejoint une partie (`join_open_game` insère un participant) ou qui la
//    quitte (`leave_open_game` supprime sa ligne) ne déclenche donc aucun
//    événement ; seuls la création d'une partie et son annulation (mise à
//    jour de `reservations`) rafraîchissent la liste en direct. Le reste se
//    voit au « tirer pour actualiser » ou à la relecture suivante.
//

import Foundation
import Observation
import Supabase

/// Magasin des parties ouvertes du club et des fiches de leurs joueurs.
@Observable
final class OpenGamesStore {

    /// Avancement du chargement.
    enum Phase: Equatable {
        /// Rien n'a encore été demandé.
        case idle
        /// Premier chargement en cours.
        case loading
        /// Liste disponible (éventuellement vide).
        case ready
        /// Lecture impossible alors qu'aucune partie n'était affichée.
        case failed(String)
    }

    /// Avancement, observé par les écrans.
    private(set) var phase: Phase = .idle
    /// Toutes les parties ouvertes confirmées, du jour et à venir, triées par
    /// date puis heure, complètes comprises.
    private(set) var games: [OpenGame] = []

    /// Photos, âges et classements des joueurs affichés, indexés par profil.
    ///
    /// Rechargé à chaque lecture plutôt que mémorisé durablement : l'âge est
    /// calculé côté base, le figer le rendrait faux au lendemain d'un
    /// anniversaire.
    private(set) var roster: [UUID: RosterInfoRow] = [:]

    /// Club des parties chargées.
    private var clubId: UUID?
    /// Relecture différée en attente (voir `scheduleReload`).
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    // MARK: - Lectures dérivées

    /// Parties affichées : ni complètes, ni commencées, ni annulées.
    ///
    /// - Parameter sport: filtre de sport, `nil` pour tous.
    /// - Returns: les parties qu'on peut encore rejoindre, dans l'ordre
    ///   chronologique.
    func openForJoining(sport: Sport?) -> [OpenGame] {
        games
            .filter(\.isOpenForJoining)
            .filter { sport == nil || $0.sport == sport }
    }

    /// Sports ayant au moins une partie à rejoindre, pour n'afficher que des
    /// filtres utiles.
    /// Dans l'ordre tennis, padel, pickleball.
    var sportsWithGames: [Sport] {
        let played = Set(games.filter(\.isOpenForJoining).map(\.sport))
        return Sport.allCases.filter(played.contains)
    }

    /// Suis-je déjà engagé dans une partie ouverte ce jour-là ?
    ///
    /// Sert à expliquer le refus avant tout envoi : la base applique la même
    /// règle (déclencheur `one_open_game_per_day` sur
    /// `reservation_participants`), tous sports confondus. Seules les parties
    /// chargées comptent, c'est-à-dire celles d'aujourd'hui et des jours
    /// suivants.
    ///
    /// - Parameters:
    ///   - profileId: membre concerné (soi, ou l'enfant sélectionné).
    ///   - date: jour visé ; comparé au jour près (fuseau de l'appareil).
    ///   - excluding: partie à ignorer, pour ne pas se refuser
    ///     l'adhésion à cause de sa propre présence dans la partie visée.
    /// - Returns: vrai si le membre figure dans une autre partie non annulée
    ///   ce jour-là.
    func isEngaged(profileId: UUID, on date: Date, excluding gameId: UUID? = nil) -> Bool {
        let calendar = Calendar.current
        return games.contains { game in
            game.id != gameId
                && !game.isCancelled
                && calendar.isDate(game.date, inSameDayAs: date)
                && game.contains(profileId)
        }
    }

    /// Parties où je figure, pour « Mes réservations ».
    ///
    /// Code non utilisé à ce jour : « Mes réservations » lit ses parties par
    /// `ReservationsStore`.
    ///
    /// - Parameter profileId: membre concerné.
    /// - Returns: les parties chargées où il est inscrit.
    func games(containing profileId: UUID) -> [OpenGame] {
        games.filter { $0.contains(profileId) }
    }

    /// Partie chargée portant cet identifiant.
    ///
    /// - Parameter id: identifiant de la réservation de la partie.
    /// - Returns: la partie, ou `nil` si elle n'est pas (ou plus) dans la liste.
    func game(id: UUID) -> OpenGame? {
        games.first { $0.id == id }
    }

    // MARK: - Cycle de vie

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    /// À utiliser depuis un `.task(id:)`, qui gère le démontage.
    ///
    /// - Parameter clubId: club dont on lit les parties.
    func activate(clubId: UUID) async {
        self.clubId = clubId
        await reload()
        await observeChanges(clubId: clubId)
    }

    /// Charge sans s'abonner, si rien ne l'a encore fait. Pour un écran poussé
    /// avant que la racine de l'onglet n'ait lancé `activate`.
    ///
    /// - Parameter clubId: club dont on lit les parties.
    func ensureLoaded(clubId: UUID) async {
        guard phase == .idle else { return }
        self.clubId = clubId
        await reload()
    }

    /// Relit toutes les parties, puis les fiches de leurs joueurs.
    func reload() async {
        guard let clubId else { return }
        // Indicateur de chargement seulement quand rien n'est affiché.
        if games.isEmpty { phase = .loading }

        do {
            games = try await OpenGameService.loadAll(clubId: clubId)
            phase = .ready
            await loadRoster()
        } catch {
            // On garde la liste déjà chargée : une coupure réseau ne doit pas
            // vider l'écran.
            phase = games.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }

    /// Un seul appel pour tous les joueurs de toutes les parties. Tolérant à
    /// l'échec : sans lui les vignettes gardent le prénom et les initiales.
    private func loadRoster() async {
        // Identifiants distincts de tous les joueurs inscrits.
        let ids = Array(Set(games.flatMap { $0.players.map(\.profileId) }))
        guard !ids.isEmpty else {
            roster = [:]
            return
        }
        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
    }

    // MARK: - Temps réel

    /// Écoute `reservations` et `reservation_participants` jusqu'à
    /// l'annulation de la tâche appelante ; tout événement demande une
    /// relecture groupée. Aucun filtre sur les événements : la RLS ne
    /// transmet que ceux des clubs du membre.
    ///
    /// - Parameter clubId: club suivi, qui sert à nommer le canal.
    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("open-games-\(clubId.uuidString)")
        let reservationChanges = channel.postgresChange(
            AnyAction.self, schema: "public", table: "reservations"
        )
        // Voir « Points d'attention » : cette table n'est pas publiée, ce
        // flux ne reçoit rien.
        let participantChanges = channel.postgresChange(
            AnyAction.self, schema: "public", table: "reservation_participants"
        )

        // Un abonnement qui échoue ne doit pas casser l'écran : la liste reste
        // exacte au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Un consommateur par flux ; le groupe ne se termine qu'à l'annulation.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await _ in reservationChanges { await self?.scheduleReload() }
            }
            group.addTask { [weak self] in
                for await _ in participantChanges { await self?.scheduleReload() }
            }
        }
    }

    /// Rejoindre une partie émet plusieurs événements d'affilée (participant
    /// inséré, réservation touchée). On les regroupe derrière un court délai.
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
