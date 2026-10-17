//
//  GuestCredit.swift
//  iClub
//
//  Crédits invités.
//
//  Il n'existe aucun compteur stocké qui se décrémente : le solde est recalculé
//  à chaque ouverture du tunnel, ce qui le rend impossible à désynchroniser.
//  Une annulation restitue donc le crédit sans écriture supplémentaire.
//

import Foundation

nonisolated struct GuestCreditBalance: Equatable, Sendable {
    /// Dotation de la période d'adhésion en cours.
    let total: Int
    /// Crédits déjà consommés par des réservations existantes.
    let used: Int

    /// Crédits encore disponibles, hors panier en cours.
    var available: Int { max(0, total - used) }

    /// Un membre sans adhésion active n'a aucun crédit : l'option est
    /// simplement indisponible.
    static let none = GuestCreditBalance(total: 0, used: 0)

    /// Dotation appliquée quand l'admin n'a rien réglé pour ce membre.
    static let defaultTotal = 2
}

// MARK: - DTO

nonisolated struct GuestCreditAllowanceRow: Decodable, Sendable {
    let total: Int?

    static let columns = "club_member_id, period_start, total"
}

/// Réservation créée par le membre sur la période d'adhésion, avec ses
/// participants pris sur crédit. Le comptage se fait ici plutôt qu'en SQL :
/// la règle des 2 heures a besoin de `cancelled_at` comparé à l'heure de début.
nonisolated struct CreditUsageRow: Decodable, Sendable {
    let date: String?
    let heureDebut: String?
    let statut: String?
    let cancelledAt: String?
    let participants: [Participant]

    nonisolated struct Participant: Decodable, Sendable {
        let usedCredit: Bool?

        enum CodingKeys: String, CodingKey {
            case usedCredit = "used_credit"
        }
    }

    enum CodingKeys: String, CodingKey {
        case date, statut
        case heureDebut = "heure_debut"
        case cancelledAt = "cancelled_at"
        case participants = "reservation_participants"
    }

    static let columns =
        "date, heure_debut, statut, cancelled_at, reservation_participants(used_credit)"

    /// Nombre de crédits que cette réservation retient encore.
    var creditsStillCounted: Int {
        guard countsTowardBalance else { return 0 }
        return participants.filter { $0.usedCredit == true }.count
    }

    /// Une réservation annulée libère son crédit **seulement** si l'annulation
    /// a eu lieu au moins 2 heures avant l'heure de début. Annulée plus tard,
    /// le crédit reste consommé.
    private var countsTowardBalance: Bool {
        if statut == ReservationInsert.confirmedStatus { return true }
        guard statut == ReservationInsert.cancelledStatus,
              let cancelledAt = SupabaseDate.parse(cancelledAt),
              let start = SupabaseDate.dateTime(day: date, time: heureDebut)
        else { return false }

        return cancelledAt >= start.addingTimeInterval(-2 * 3600)
    }
}
