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
//  Place dans l'application
//    `GuestCreditService.balance` lit `guest_credit_allowances` et
//    `reservations` avec ces DTO ; le solde est affiché par l'accueil et
//    consommé par le tunnel de réservation (`BookingDraft`).
//
//  Règles métier (mêmes que le web, `src/lib/guestCreditRules.ts`)
//    - Dotation : la ligne `guest_credit_allowances` du membre pour sa période
//      d'adhésion, sinon 2 crédits.
//    - Un crédit reste consommé tant que la réservation est confirmée, ou si
//      elle a été annulée moins de 2 heures avant son début.
//

import Foundation

/// Solde de crédits invités du membre pour sa période d'adhésion.
nonisolated struct GuestCreditBalance: Equatable, Sendable {
    /// Dotation de la période d'adhésion en cours.
    let total: Int
    /// Crédits déjà consommés par des réservations existantes.
    let used: Int

    /// Crédits encore disponibles, hors panier en cours.
    /// Jamais négatif.
    var available: Int { max(0, total - used) }

    /// Un membre sans adhésion active n'a aucun crédit : l'option est
    /// simplement indisponible.
    static let none = GuestCreditBalance(total: 0, used: 0)

    /// Dotation appliquée quand l'admin n'a rien réglé pour ce membre.
    /// (Même valeur que `GUEST_CREDIT_TOTAL` côté web.)
    static let defaultTotal = 2
}

// MARK: - DTO

/// Ligne de `guest_credit_allowances` : dotation réglée par l'admin pour un
/// membre et une période (unicité `club_member_id, period_start`).
nonisolated struct GuestCreditAllowanceRow: Decodable, Sendable {
    /// `total` : nombre de crédits de la période.
    let total: Int?

    /// Colonnes demandées ; seule `total` est décodée.
    static let columns = "club_member_id, period_start, total"
}

/// Réservation créée par le membre sur la période d'adhésion, avec ses
/// participants pris sur crédit. Le comptage se fait ici plutôt qu'en SQL :
/// la règle des 2 heures a besoin de `cancelled_at` comparé à l'heure de début.
nonisolated struct CreditUsageRow: Decodable, Sendable {
    /// `date` (`date`), en texte.
    let date: String?
    /// `heure_debut` (`time`), en texte.
    let heureDebut: String?
    /// `statut` : `confirmee` ou `annulee`.
    let statut: String?
    /// `cancelled_at` (`timestamptz`), en texte ; `nil` si jamais annulée.
    let cancelledAt: String?
    /// Participants joints, réduits à leur drapeau de crédit.
    let participants: [Participant]

    /// Participant joint (`reservation_participants`).
    nonisolated struct Participant: Decodable, Sendable {
        /// `used_credit` : place prise sur un crédit invité.
        let usedCredit: Bool?

        /// Correspondance avec la colonne SQL.
        enum CodingKeys: String, CodingKey {
            case usedCredit = "used_credit"
        }
    }

    /// Correspondance avec les colonnes SQL et la jointure.
    enum CodingKeys: String, CodingKey {
        case date, statut
        case heureDebut = "heure_debut"
        case cancelledAt = "cancelled_at"
        case participants = "reservation_participants"
    }

    /// Sélection PostgREST, avec la jointure sur les participants.
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
    ///
    /// Une réservation annulée dont la date ou l'heure est illisible ne compte
    /// pas. Le début est calculé dans le fuseau de l'appareil.
    private var countsTowardBalance: Bool {
        if statut == ReservationInsert.confirmedStatus { return true }
        guard statut == ReservationInsert.cancelledStatus,
              let cancelledAt = SupabaseDate.parse(cancelledAt),
              let start = SupabaseDate.dateTime(day: date, time: heureDebut)
        else { return false }

        // 2 × 3 600 secondes : la limite de 2 heures avant le début.
        return cancelledAt >= start.addingTimeInterval(-2 * 3600)
    }
}
