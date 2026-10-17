//
//  GuestCreditService.swift
//  iClub
//
//  Calcul du solde de crédits invités.
//
//  Aucun compteur n'est stocké : le solde est recalculé à chaque ouverture du
//  tunnel. C'est ce qui le rend impossible à désynchroniser, et c'est aussi
//  pourquoi une annulation restitue le crédit sans écriture supplémentaire.
//
//    total     ← `guest_credit_allowances` pour (membre, début d'adhésion),
//                sinon la dotation par défaut
//    consommés ← participants sur crédit des réservations que j'ai créées sur
//                la période d'adhésion, en appliquant la règle des 2 heures
//    restant   = total − consommés  (le panier en cours est déduit côté vue)
//

import Foundation
import Supabase

enum GuestCreditService {

    /// - Parameter period: période de l'adhésion active. `nil` (aucune
    ///   adhésion) donne un solde nul : l'option crédit est indisponible.
    static func balance(
        clubId: UUID,
        clubMemberId: UUID,
        profileId: UUID,
        period: (debut: Date, fin: Date)?
    ) async -> GuestCreditBalance {
        guard let period else { return .none }

        let total = await allowanceTotal(clubMemberId: clubMemberId, periodStart: period.debut)

        do {
            let used = try await usedCredits(clubId: clubId, profileId: profileId, period: period)
            return GuestCreditBalance(total: total, used: used)
        } catch {
            // Compter zéro consommé laisserait croire à des crédits
            // disponibles et produirait un refus côté base au moment de
            // confirmer. On considère la dotation épuisée : l'utilisateur peut
            // toujours choisir « payer le supplément ».
            return GuestCreditBalance(total: total, used: total)
        }
    }

    // MARK: - Dotation

    /// Une ligne d'allocation fait foi : c'est un réglage que l'admin peut
    /// modifier membre par membre. Son absence n'est pas une erreur.
    private static func allowanceTotal(clubMemberId: UUID, periodStart: Date) async -> Int {
        do {
            let rows: [Lenient<GuestCreditAllowanceRow>] = try await Supa.client
                .from("guest_credit_allowances")
                .select(GuestCreditAllowanceRow.columns)
                .eq("club_member_id", value: clubMemberId.uuidString)
                .eq("period_start", value: SupabaseDate.day(from: periodStart))
                .limit(1)
                .execute()
                .value

            if let total = rows.compactValues().first?.total { return total }
        } catch {
            // Un échec de lecture ne doit pas priver le membre de ses crédits :
            // on retombe sur la dotation par défaut.
        }
        return GuestCreditBalance.defaultTotal
    }

    // MARK: - Consommés

    private static func usedCredits(
        clubId: UUID,
        profileId: UUID,
        period: (debut: Date, fin: Date)
    ) async throws -> Int {
        let rows: [Lenient<CreditUsageRow>] = try await Supa.client
            .from("reservations")
            .select(CreditUsageRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("created_by", value: profileId.uuidString)
            .gte("date", value: SupabaseDate.day(from: period.debut))
            .lte("date", value: SupabaseDate.day(from: period.fin))
            .execute()
            .value

        return rows.compactValues().reduce(0) { $0 + $1.creditsStillCounted }
    }
}
