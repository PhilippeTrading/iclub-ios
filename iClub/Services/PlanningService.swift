//
//  PlanningService.swift
//  iClub
//
//  Lecture du catalogue du club : terrains et horaires par sport. Ces données
//  sont administrées depuis le back-office web, l'app ne fait que les refléter.
//

import Foundation
import Supabase

enum PlanningService {

    /// Terrains actifs du club, triés par `ordre` (l'ordre choisi par l'admin).
    /// Les terrains inactifs et les sports inconnus de l'app sont écartés ici,
    /// jamais affichés.
    static func loadCourts(clubId: UUID) async throws -> [Court] {
        let rows: [Lenient<CourtRow>] = try await Supa.client
            .from("courts")
            .select(CourtRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("actif", value: true)
            .order("ordre", ascending: true)
            .execute()
            .value

        return rows.compactValues().compactMap { $0.toDomain() }
    }

    /// Horaires par sport. Tolérant : un sport sans ligne prend les valeurs de
    /// repli plutôt que de disparaître du planning.
    static func loadSportSettings(clubId: UUID) async -> [Sport: ClubSportSettings] {
        do {
            let rows: [Lenient<ClubSportSettingsRow>] = try await Supa.client
                .from("club_sport_settings")
                .select(ClubSportSettingsRow.columns)
                .eq("club_id", value: clubId.uuidString)
                .execute()
                .value

            let settings = rows.compactValues().compactMap { $0.toDomain() }
            return Dictionary(uniqueKeysWithValues: settings.map { ($0.sport, $0) })
        } catch {
            return [:]
        }
    }

    /// Réservations occupant un créneau ce jour-là. Seules les `confirmee`
    /// comptent : une réservation annulée libère le créneau.
    ///
    /// Aucun filtre par sport — la clé de croisement est `court_id`, et charger
    /// tout le club en une requête évite un aller-retour par changement de sport.
    static func loadReservations(clubId: UUID, date: Date) async throws -> [ReservationRow] {
        let rows: [Lenient<ReservationRow>] = try await Supa.client
            .from("reservations")
            .select(ReservationRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("date", value: SupabaseDate.day(from: date))
            .eq("statut", value: ReservationInsert.confirmedStatus)
            .execute()
            .value

        return rows.compactValues()
    }

    /// Blocages posés par l'admin ce jour-là (entretien, cours, tournoi…).
    static func loadSlotOverrides(clubId: UUID, date: Date) async throws -> [SlotOverrideRow] {
        let rows: [Lenient<SlotOverrideRow>] = try await Supa.client
            .from("slot_overrides")
            .select(SlotOverrideRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("date", value: SupabaseDate.day(from: date))
            .execute()
            .value

        return rows.compactValues()
    }

    // MARK: - Terrains fermés

    private nonisolated struct ForbiddenCourtRow: Decodable, Sendable {
        let courtId: UUID
        enum CodingKeys: String, CodingKey { case courtId = "court_id" }
    }

    private nonisolated struct ForbiddenParams: Encodable, Sendable {
        let clubId: UUID
        let profileId: UUID?
        enum CodingKeys: String, CodingKey {
            case clubId = "p_club_id"
            case profileId = "p_profile_id"
        }
    }

    /// Terrains que l'utilisateur connecté — ou l'enfant donné — ne peut pas
    /// réserver. Seule source : `terrains_interdits` ; la table des fermetures
    /// n'est pas lisible par un adhérent.
    ///
    /// En cas d'échec (réseau, fonction pas encore déployée), on ne cache rien :
    /// la base refusera une réservation interdite avec un message clair.
    static func forbiddenCourts(clubId: UUID, for childId: UUID? = nil) async -> Set<UUID> {
        do {
            // Sans enfant, le paramètre est omis : la base choisit alors la
            // version à un argument, pour l'utilisateur connecté.
            let rows: [ForbiddenCourtRow] = try await Supa.client
                .rpc("terrains_interdits", params: ForbiddenParams(clubId: clubId, profileId: childId))
                .execute()
                .value
            return Set(rows.map(\.courtId))
        } catch {
            return []
        }
    }
}
