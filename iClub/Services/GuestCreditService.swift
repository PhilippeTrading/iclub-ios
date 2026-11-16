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
//  Place dans l'application
//    Appelé par l'accueil (`HomeStore`, carte des crédits) et par le tunnel de
//    réservation (`BookingDraft`, choix crédit ou supplément pour un invité).
//
//  Tables lues
//    `guest_credit_allowances` (RLS : le membre concerné ou l'administration)
//    et `reservations` jointe à `reservation_participants` (RLS : membres du
//    club). Aucune écriture.
//
//  Droits et sécurité
//    Ce calcul sert l'affichage et le choix proposé. Aucune règle de la base ne
//    revérifie le solde quand une réservation est enregistrée avec
//    `used_credit = true` : le contrôle repose sur les applications (le web
//    fait le même calcul, `src/lib/data/guestCredits.ts`).
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Aucun cache.
//

import Foundation
import Supabase

/// Solde des crédits invités d'un membre.
enum GuestCreditService {

    /// Solde de crédits invités du membre pour sa période d'adhésion.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - clubMemberId: appartenance du membre (`club_members.id`), clé de la
    ///     dotation.
    ///   - profileId: profil du membre, créateur des réservations comptées.
    ///   - period: période de l'adhésion active. `nil` (aucune
    ///     adhésion) donne un solde nul : l'option crédit est indisponible.
    /// - Returns: le solde ; jamais d'erreur levée (voir les replis ci-dessous).
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
            // disponibles ; la base ne revérifiant pas le solde, la réservation
            // passerait avec des crédits en trop. On considère la dotation
            // épuisée : l'utilisateur peut toujours choisir « payer le
            // supplément ». (Le web, lui, compte zéro consommé en cas d'erreur.)
            return GuestCreditBalance(total: total, used: total)
        }
    }

    // MARK: - Dotation

    /// Une ligne d'allocation fait foi : c'est un réglage que l'admin peut
    /// modifier membre par membre. Son absence n'est pas une erreur.
    ///
    /// - Parameters:
    ///   - clubMemberId: appartenance du membre.
    ///   - periodStart: début de l'adhésion active (`period_start` de la ligne).
    /// - Returns: le total réglé par l'admin, sinon `GuestCreditBalance.defaultTotal`.
    private static func allowanceTotal(clubMemberId: UUID, periodStart: Date) async -> Int {
        do {
            // Une ligne au plus par (membre, début de période) : contrainte
            // d'unicité de la table.
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

    /// Crédits encore retenus par les réservations du membre sur la période.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - profileId: créateur des réservations (`created_by`).
    ///   - period: période d'adhésion, bornes incluses.
    /// - Returns: nombre de participants sur crédit encore comptés.
    /// - Throws: l'erreur de la requête (traitée par `balance`).
    private static func usedCredits(
        clubId: UUID,
        profileId: UUID,
        period: (debut: Date, fin: Date)
    ) async throws -> Int {
        // Toutes les réservations créées par le membre sur la période, annulées
        // comprises (la règle des 2 heures les départage), avec leurs
        // participants. Pas de pagination : au-delà de la limite de lignes de
        // l'API (mille par défaut sur Supabase), le décompte serait tronqué.
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
