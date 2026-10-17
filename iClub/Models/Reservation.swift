//
//  Reservation.swift
//  iClub
//
//  Lecture et écriture de `reservations` et `reservation_participants`.
//
//  Seules les lignes `statut = 'confirmee'` occupent un créneau : une
//  réservation annulée le libère, et n'est pas supprimée — elle reste en base
//  avec son `cancelled_at`, dont dépend la restitution du crédit invité.
//

import Foundation

// MARK: - Lecture (disponibilités)

nonisolated struct ReservationRow: Decodable, Sendable {
    let id: UUID
    let courtId: UUID
    let heureDebut: String?

    enum CodingKeys: String, CodingKey {
        case id
        case courtId = "court_id"
        case heureDebut = "heure_debut"
    }

    static let columns = "id, court_id, heure_debut"

    /// Début de la réservation, en minutes depuis minuit.
    var startMinutes: Int? {
        ClubSportSettingsRow.minutes(from: heureDebut)
    }
}

// MARK: - Écriture

/// Charge utile d'insertion. `statut` est écrit explicitement plutôt que laissé
/// au défaut de la base, pour que la ligne créée par l'app soit identique à
/// celle créée par le web.
nonisolated struct ReservationInsert: Encodable, Sendable {
    let clubId: UUID
    let courtId: UUID
    let date: String
    let heureDebut: String
    let heureFin: String
    let format: String
    let statut: String
    let statutPaiement: String
    let montantTotal: Double
    /// `nil` quand rien n'est à régler : aucun mode de paiement n'a de sens.
    let modePaiement: String?
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case date, format, statut
        case clubId = "club_id"
        case courtId = "court_id"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case statutPaiement = "statut_paiement"
        case montantTotal = "montant_total"
        case modePaiement = "mode_paiement"
        case createdBy = "created_by"
    }

    static let confirmedStatus = "confirmee"
    static let cancelledStatus = "annulee"

    /// `statut_paiement` : « payé » dès qu'un supplément est dû, « inclus »
    /// quand la partie est couverte par les adhésions.
    static func paymentStatus(total: Double) -> String {
        total > 0 ? "paye" : "inclus"
    }
}

/// Une ligne par participant. L'insertion se fait en lot, après la réservation.
nonisolated struct ReservationParticipantInsert: Encodable, Sendable {
    let reservationId: UUID
    /// `nil` pour un invité non-membre.
    let profileId: UUID?
    let type: String
    let nomAffiche: String
    let supplement: Double
    let usedCredit: Bool

    enum CodingKeys: String, CodingKey {
        case type, supplement
        case reservationId = "reservation_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case usedCredit = "used_credit"
    }
}

/// Mise à jour d'annulation. La ligne est conservée : c'est `cancelled_at` qui
/// détermine si le crédit invité est restitué.
nonisolated struct ReservationCancelUpdate: Encodable, Sendable {
    let statut: String
    let cancelledAt: String
    let cancelledBy: UUID

    enum CodingKeys: String, CodingKey {
        case statut
        case cancelledAt = "cancelled_at"
        case cancelledBy = "cancelled_by"
    }

    init(by profileId: UUID, at date: Date = .now) {
        self.statut = ReservationInsert.cancelledStatus
        self.cancelledAt = date.formatted(.iso8601)
        self.cancelledBy = profileId
    }
}

/// Identifiant renvoyé par l'insertion, nécessaire pour rattacher les
/// participants et pour pouvoir supprimer la réservation si leur insertion échoue.
nonisolated struct InsertedReservationId: Decodable, Sendable {
    let id: UUID
}

// MARK: - Mode de paiement

/// Aucune intégration bancaire n'est branchée : ce sont des intentions
/// enregistrées en base, que le club traite ensuite.
nonisolated enum PaymentMode: String, CaseIterable, Identifiable, Sendable {
    case carte
    case lien
    case surplace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .carte: "Payer maintenant par carte"
        case .lien: "Envoyer le lien de paiement à l'invité"
        case .surplace: "Payer sur place"
        }
    }

    var systemImage: String {
        switch self {
        case .carte: "creditcard"
        case .lien: "paperplane"
        case .surplace: "building.2"
        }
    }
}
