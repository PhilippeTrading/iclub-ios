//
//  PlanningService.swift
//  iClub
//
//  Lecture du catalogue du club : terrains et horaires par sport. Ces données
//  sont administrées depuis le back-office web, l'app ne fait que les refléter.
//
//  Place dans l'application
//    `ClubCatalog` (terrains, horaires, terrains fermés), `DayAvailabilityStore`
//    (réservations et blocages du jour affiché, relus à chaque événement temps
//    réel), et l'écran de récapitulatif d'une réservation (terrains fermés à
//    un enfant, vérifiés juste avant de confirmer).
//
//  Tables et fonctions SQL
//    - `courts` et `club_sport_settings` : lecture publique (catalogue).
//    - `reservations` et `slot_overrides` : lecture par les membres du club
//      (RLS `reservations_select_club`, `slot_overrides_select_club`).
//    - `terrains_interdits(p_club_id, p_profile_id)` : fonction `security
//      definer` de la migration `20261030100000_acces_terrains_groupes.sql`.
//    Aucune écriture.
//
//  Gestion des erreurs
//    Terrains, réservations et blocages lèvent l'erreur (l'écran l'affiche) ;
//    horaires et terrains fermés retombent sur une valeur neutre.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Aucun cache ici : `ClubCatalog` et `DayAvailabilityStore` gardent les
//    résultats.
//

import Foundation
import Supabase

/// Lectures du planning : terrains, horaires, occupation d'un jour.
enum PlanningService {

    /// Terrains actifs du club, triés par `ordre` (l'ordre choisi par l'admin).
    /// Les terrains inactifs et les sports inconnus de l'app sont écartés ici,
    /// jamais affichés.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: les terrains, dans l'ordre de la colonne `ordre`.
    /// - Throws: l'erreur de la requête (réseau, droits).
    static func loadCourts(clubId: UUID) async throws -> [Court] {
        let rows: [Lenient<CourtRow>] = try await Supa.client
            .from("courts")
            .select(CourtRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("actif", value: true)
            .order("ordre", ascending: true)
            .execute()
            .value

        // Ligne illisible écartée seule ; `toDomain` écarte inactifs et sports
        // inconnus.
        return rows.compactValues().compactMap { $0.toDomain() }
    }

    /// Horaires par sport. Tolérant : un sport sans ligne prend les valeurs de
    /// repli plutôt que de disparaître du planning.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: un réglage par sport présent en base ; dictionnaire vide en
    ///   cas d'échec (chaque sport prend alors le repli de
    ///   `ClubSportSettings.fallback`).
    static func loadSportSettings(clubId: UUID) async -> [Sport: ClubSportSettings] {
        do {
            let rows: [Lenient<ClubSportSettingsRow>] = try await Supa.client
                .from("club_sport_settings")
                .select(ClubSportSettingsRow.columns)
                .eq("club_id", value: clubId.uuidString)
                .execute()
                .value

            let settings = rows.compactValues().compactMap { $0.toDomain() }
            // Clé primaire (club_id, sport) : au plus une ligne par sport, les
            // clés sont donc uniques.
            return Dictionary(uniqueKeysWithValues: settings.map { ($0.sport, $0) })
        } catch {
            return [:]
        }
    }

    /// Réservations occupant un créneau ce jour-là. Seules les `confirmee`
    /// comptent : une réservation annulée libère le créneau.
    ///
    /// Aucun filtre par sport : la clé de croisement est `court_id`, et charger
    /// tout le club en une requête évite un aller-retour par changement de sport.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - date: jour affiché (converti en « AAAA-MM-JJ », fuseau de l'appareil).
    /// - Returns: les réservations confirmées du jour.
    /// - Throws: l'erreur de la requête.
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
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - date: jour affiché.
    /// - Returns: les blocages du jour, tous terrains confondus.
    /// - Throws: l'erreur de la requête.
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

    /// Ligne rendue par `terrains_interdits` : `[{ "court_id": … }]`.
    private nonisolated struct ForbiddenCourtRow: Decodable, Sendable {
        /// Terrain que la personne ne peut pas réserver.
        let courtId: UUID
        /// Correspondance avec la colonne rendue.
        enum CodingKeys: String, CodingKey { case courtId = "court_id" }
    }

    /// Paramètres de `terrains_interdits`.
    ///
    /// Encodage synthétisé : un `profileId` nul est omis de la requête (et non
    /// envoyé à `null`).
    private nonisolated struct ForbiddenParams: Encodable, Sendable {
        /// `p_club_id`.
        let clubId: UUID
        /// `p_profile_id` : l'enfant concerné, ou `nil` pour l'appelant.
        let profileId: UUID?
        /// Noms des paramètres de la fonction SQL.
        enum CodingKeys: String, CodingKey {
            case clubId = "p_club_id"
            case profileId = "p_profile_id"
        }
    }

    /// Terrains que l'utilisateur connecté, ou l'enfant donné, ne peut pas
    /// réserver. Seule source : `terrains_interdits` ; la table des fermetures
    /// n'est pas lisible par un adhérent.
    ///
    /// En cas d'échec (réseau, fonction pas encore déployée), on ne cache rien :
    /// la base refusera une réservation interdite avec un message clair.
    ///
    /// La fonction ne rend rien pour un profil sur lequel l'appelant n'a pas de
    /// droit (ni lui-même, ni un enfant qu'il peut faire réserver, sauf pour
    /// l'administration du club) : on ne lit pas les groupes des autres.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - childId: enfant au nom de qui l'on réserve, `nil` pour soi.
    /// - Returns: identifiants des terrains fermés ; ensemble vide en cas d'échec.
    static func forbiddenCourts(clubId: UUID, for childId: UUID? = nil) async -> Set<UUID> {
        do {
            // Sans enfant, le paramètre est omis : la fonction prend alors sa
            // valeur par défaut (`null`), c'est-à-dire l'utilisateur connecté.
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
