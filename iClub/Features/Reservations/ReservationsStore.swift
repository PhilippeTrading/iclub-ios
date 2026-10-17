//
//  ReservationsStore.swift
//  iClub
//
//  Réservations de l'utilisateur : celles qu'il a créées **et** celles où il
//  figure comme participant. Un membre ajouté par quelqu'un d'autre doit
//  retrouver la partie chez lui.
//

import Foundation
import Observation

@Observable
final class ReservationsStore {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var reservations: [MyReservation] = []

    /// Photos et classements des participants, indexés par profil.
    ///
    /// `reservation_participants` ne porte que `nom_affiche` : la photo d'un
    /// autre membre passe obligatoirement par `get_club_roster_info`, les
    /// règles de sécurité interdisant de lire sa fiche directement.
    private(set) var roster: [UUID: RosterInfoRow] = [:]

    private var clubId: UUID?
    private var profileId: UUID?

    /// À venir, de la plus proche à la plus lointaine.
    var upcoming: [MyReservation] {
        reservations
            .filter(\.isUpcoming)
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// Passées, de la plus récente à la plus ancienne : c'est l'ordre utile.
    var past: [MyReservation] {
        reservations
            .filter { !$0.isUpcoming }
            .sorted { $0.startsAt > $1.startsAt }
    }

    func load(clubId: UUID, profileId: UUID) async {
        self.clubId = clubId
        self.profileId = profileId

        if reservations.isEmpty { phase = .loading }

        do {
            reservations = try await ReservationService.loadMine(clubId: clubId, profileId: profileId)
            phase = .ready
            await loadRoster()
        } catch {
            // On garde la liste déjà chargée : une coupure réseau ne doit pas
            // vider l'écran.
            phase = reservations.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }

    func reload() async {
        guard let clubId, let profileId else { return }
        await load(clubId: clubId, profileId: profileId)
    }

    /// Un seul appel pour tous les participants de toutes les réservations.
    /// Tolérant à l'échec : sans lui les vignettes gardent leurs initiales.
    ///
    /// Les invités n'ont pas de `profile_id` et sont donc absents du résultat —
    /// ils conservent leurs initiales, ce qui est correct : ils n'ont pas de
    /// fiche au club.
    private func loadRoster() async {
        let ids = Array(Set(reservations.flatMap { $0.participants.compactMap(\.profileId) }))
        guard !ids.isEmpty else {
            roster = [:]
            return
        }
        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
    }
}
