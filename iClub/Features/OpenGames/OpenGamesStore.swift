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

import Foundation
import Observation
import Supabase

@Observable
final class OpenGamesStore {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var games: [OpenGame] = []

    /// Photos, âges et classements des joueurs affichés, indexés par profil.
    ///
    /// Rechargé à chaque lecture plutôt que mémorisé durablement : l'âge est
    /// calculé côté base, le figer le rendrait faux au lendemain d'un
    /// anniversaire.
    private(set) var roster: [UUID: RosterInfoRow] = [:]

    private var clubId: UUID?
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    // MARK: - Lectures dérivées

    /// Parties affichées : ni complètes, ni commencées, ni annulées.
    func openForJoining(sport: Sport?) -> [OpenGame] {
        games
            .filter(\.isOpenForJoining)
            .filter { sport == nil || $0.sport == sport }
    }

    /// Sports ayant au moins une partie à rejoindre, pour n'afficher que des
    /// filtres utiles.
    var sportsWithGames: [Sport] {
        let played = Set(games.filter(\.isOpenForJoining).map(\.sport))
        return Sport.allCases.filter(played.contains)
    }

    /// Suis-je déjà engagé dans une partie ouverte ce jour-là ?
    ///
    /// - Parameter excluding: partie à ignorer, pour ne pas se refuser
    ///   l'adhésion à cause de sa propre présence dans la partie visée.
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
    func games(containing profileId: UUID) -> [OpenGame] {
        games.filter { $0.contains(profileId) }
    }

    func game(id: UUID) -> OpenGame? {
        games.first { $0.id == id }
    }

    // MARK: - Cycle de vie

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    /// À utiliser depuis un `.task(id:)`, qui gère le démontage.
    func activate(clubId: UUID) async {
        self.clubId = clubId
        await reload()
        await observeChanges(clubId: clubId)
    }

    func reload() async {
        guard let clubId else { return }
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
        let ids = Array(Set(games.flatMap { $0.players.map(\.profileId) }))
        guard !ids.isEmpty else {
            roster = [:]
            return
        }
        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
    }

    // MARK: - Temps réel

    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("open-games-\(clubId.uuidString)")
        let reservationChanges = channel.postgresChange(
            AnyAction.self, schema: "public", table: "reservations"
        )
        let participantChanges = channel.postgresChange(
            AnyAction.self, schema: "public", table: "reservation_participants"
        )

        // Un abonnement qui échoue ne doit pas casser l'écran : la liste reste
        // exacte au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

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
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
