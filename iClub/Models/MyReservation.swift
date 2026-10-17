//
//  MyReservation.swift
//  iClub
//
//  Réservations de l'utilisateur pour l'onglet « Réservations ».
//
//  Une réservation apparaît si je l'ai créée **ou** si j'y figure comme
//  participant : un membre ajouté par quelqu'un d'autre doit retrouver la
//  partie chez lui. Le bouton d'annulation, lui, ne dépend que de `created_by`.
//

import Foundation

// MARK: - DTO

nonisolated struct MyReservationRow: Decodable, Sendable {
    let id: UUID
    let date: String?
    let heureDebut: String?
    let heureFin: String?
    let statut: String?
    let statutPaiement: String?
    let createdBy: UUID?
    let format: String?
    let estPartieOuverte: Bool?
    let court: CourtBrief?
    let participants: [ParticipantBrief]

    nonisolated struct CourtBrief: Decodable, Sendable {
        let nom: String?
        let surface: String?
        let couvert: Bool?
        let sport: String?
    }

    nonisolated struct ParticipantBrief: Decodable, Sendable {
        let profileId: UUID?
        let nomAffiche: String?

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case nomAffiche = "nom_affiche"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, date, statut, format
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case statutPaiement = "statut_paiement"
        case createdBy = "created_by"
        case estPartieOuverte = "est_partie_ouverte"
        case court = "courts"
        case participants = "reservation_participants"
    }

    static let columns = """
        id, date, heure_debut, heure_fin, statut, statut_paiement, created_by, created_at, \
        format, est_partie_ouverte, \
        courts(nom, surface, couvert, sport), reservation_participants(profile_id, nom_affiche)
        """

    /// `nil` si la ligne n'a ni date ni heure exploitables : elle est alors
    /// écartée plutôt qu'affichée à moitié.
    func toDomain(myProfileId: UUID) -> MyReservation? {
        guard let day = SupabaseDate.parse(date),
              let startMinutes = ClubSportSettingsRow.minutes(from: heureDebut)
        else { return nil }

        // La durée se déduit des deux bornes ; à défaut, on retombe sur une
        // heure plutôt que d'afficher un créneau de longueur nulle.
        let endMinutes = ClubSportSettingsRow.minutes(from: heureFin) ?? (startMinutes + 60)

        return MyReservation(
            id: id,
            date: day,
            slot: TimeSlot(startMinutes: startMinutes, durationMinutes: max(0, endMinutes - startMinutes)),
            sport: court?.sport.flatMap { Sport(rawValue: $0.lowercased()) },
            courtName: court?.nom ?? "Terrain",
            surface: court?.surface,
            isIndoor: court?.couvert ?? false,
            isCancelled: statut == ReservationInsert.cancelledStatus,
            isPaid: statutPaiement == "paye",
            isOwner: createdBy == myProfileId,
            createdBy: createdBy,
            isOpenGame: estPartieOuverte == true,
            format: format.flatMap { GameFormat(rawValue: $0.lowercased()) },
            participants: participants.map {
                MyReservation.Participant(
                    profileId: $0.profileId,
                    displayName: $0.nomAffiche ?? "Participant"
                )
            }
        )
    }
}

/// Réservations où je figure comme joueur, première requête du couple.
nonisolated struct ParticipationRow: Decodable, Sendable {
    let reservationId: UUID

    enum CodingKeys: String, CodingKey {
        case reservationId = "reservation_id"
    }

    static let columns = "reservation_id"
}

// MARK: - Domaine

nonisolated struct MyReservation: Identifiable, Hashable, Sendable {

    nonisolated struct Participant: Identifiable, Hashable, Sendable {
        /// `nil` pour un invité non-membre : ni photo ni classement à afficher.
        let profileId: UUID?
        let displayName: String

        var id: String { profileId?.uuidString ?? displayName }

        var initials: String {
            let parts = displayName.split(separator: " ").prefix(2)
            let value = parts.compactMap { $0.first.map(String.init) }.joined()
            return value.uppercased().isEmpty ? "?" : value.uppercased()
        }
    }

    let id: UUID
    let date: Date
    let slot: TimeSlot
    let sport: Sport?
    let courtName: String
    let surface: String?
    let isIndoor: Bool
    let isCancelled: Bool
    let isPaid: Bool
    /// `true` seulement si j'ai créé la réservation : un simple participant ne
    /// peut pas annuler la réservation d'un autre.
    let isOwner: Bool
    /// Créateur de la réservation, pour marquer « Réservataire » dans la liste
    /// des joueurs même quand ce n'est pas moi.
    let createdBy: UUID?
    /// Une partie ouverte est une réservation comme les autres, distinguée par
    /// ce seul drapeau. Elle se quitte (`leave_open_game`) au lieu de s'annuler.
    let isOpenGame: Bool
    /// Nécessaire pour savoir si une partie ouverte est complète.
    let format: GameFormat?
    let participants: [Participant]

    /// Instant de début, pour trancher « à venir » / « passées ».
    var startsAt: Date {
        Calendar.current.date(byAdding: .minute, value: slot.startMinutes, to: Calendar.current.startOfDay(for: date))
            ?? date
    }

    var isUpcoming: Bool { startsAt >= .now }

    /// « Terre battue · Extérieur »
    var courtDetail: String {
        var parts: [String] = []
        if let surface, !surface.isEmpty { parts.append(surface) }
        parts.append(isIndoor ? "Intérieur" : "Extérieur")
        return parts.joined(separator: " · ")
    }

    /// Une partie ouverte complète n'apparaît plus dans « Parties ouvertes » :
    /// c'est ici qu'on le signale, et ici qu'on peut la quitter.
    var isFullOpenGame: Bool {
        guard isOpenGame, let format else { return false }
        return participants.count >= format.capacity
    }

    var statusLabel: String {
        if isCancelled { return "Annulée" }
        if isFullOpenGame { return "Partie complète" }
        return isPaid ? "Payé" : "Confirmée"
    }

    /// Libellé de l'action de sortie. L'hôte annule la partie entière ; un
    /// participant ne libère que sa place, et la partie réapparaît dans la liste.
    var leaveActionTitle: String {
        guard isOpenGame else { return "Annuler la réservation" }
        return isOwner ? "Annuler la partie" : "Quitter la partie"
    }

    var leaveConfirmationTitle: String {
        guard isOpenGame else { return "Annuler cette réservation ?" }
        return isOwner ? "Annuler cette partie ?" : "Quitter cette partie ?"
    }

    var leaveConfirmationMessage: String {
        if !isOpenGame {
            return "Le créneau redeviendra disponible pour les autres membres."
        }
        return isOwner
            ? "La partie sera annulée pour tous les joueurs et le créneau rendu au club. Il n'y a pas de transfert d'hôte."
            : "Ta place sera libérée et la partie réapparaîtra dans Parties ouvertes."
    }
}
