//
//  ActivityService.swift
//  iClub
//
//  Lecture des activités du club et inscription. Les refus (âge, niveau,
//  inscriptions fermées, complet) arrivent de la base en P0001, avec un message
//  rédigé en français : on le montre tel quel.
//

import Foundation
import Supabase

enum ActivityServiceError: LocalizedError {
    /// La migration attendue n'est pas passée : fonction inconnue.
    case unavailable
    case refused(String)
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Cette fonction n'est pas encore disponible pour votre club."
        case .refused(let message): message
        case .failed: "L'opération n'a pas abouti. Vérifiez votre connexion et réessayez."
        }
    }

    /// Traduit une erreur PostgREST en message lisible.
    static func from(_ error: Error) -> ActivityServiceError {
        if let error = error as? ActivityServiceError { return error }
        guard let error = error as? PostgrestError else { return .failed }
        switch error.code {
        case "PGRST202", "42883": return .unavailable
        case "P0001": return .refused(error.message)
        // Écriture refusée par les règles d'accès.
        case "42501": return .refused("Vous n'avez pas le droit de faire cette modification.")
        default: return .failed
        }
    }
}

extension ActivityServiceError {
    /// Les messages de la base disent encore « cette activité » : en attendant
    /// la migration du club, on dit « ce cours » ou « cet événement » selon le
    /// type, sans rien changer d'autre au message.
    func worded(for type: ActivityType) -> ActivityServiceError {
        switch self {
        case .refused(let message):
            let lower = type.demonstrative
            let upper = lower.prefix(1).uppercased() + lower.dropFirst()
            return .refused(message
                .replacingOccurrences(of: "cette activité", with: lower)
                .replacingOccurrences(of: "Cette activité", with: upper))
        default:
            return self
        }
    }
}

enum ActivityService {

    // MARK: - Lecture

    /// Activités en ligne : ni brouillon, ni proposée, ni annulée, ni terminée.
    /// « Complète » reste visible : la liste d'attente y est encore ouverte.
    static func loadPublished(clubId: UUID) async throws -> [Activity] {
        try await Supa.client
            .from("activites")
            .select(Activity.columns)
            .eq("club_id", value: clubId.uuidString)
            .in("statut", values: [ActivityStatus.ouverte.rawValue, ActivityStatus.complete.rawValue])
            .order("nom")
            .execute()
            .value
    }

    /// Activités encadrées par l'entraîneur, sauf annulées et terminées.
    static func loadCoached(clubId: UUID, coachId: UUID) async throws -> [Activity] {
        try await Supa.client
            .from("activites")
            .select(Activity.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("entraineur_profile_id", value: coachId.uuidString)
            .not("statut", operator: .in, value: "(annulee,terminee)")
            .order("nom")
            .execute()
            .value
    }

    /// Séances prévues à partir d'aujourd'hui, pour une liste d'activités.
    static func upcomingSessions(activityIds: [UUID], from day: Date = .now) async throws -> [ActivitySession] {
        guard !activityIds.isEmpty else { return [] }
        return try await Supa.client
            .from("activite_seances")
            .select(ActivitySession.columns)
            .in("activite_id", values: activityIds.map(\.uuidString))
            .eq("statut", value: SessionStatus.prevue.rawValue)
            .gte("date", value: SupabaseDate.day(from: day))
            .order("date")
            .order("heure_debut")
            .execute()
            .value
    }

    /// Toutes les séances de ces activités, passées et à venir.
    static func allSessions(activityIds: [UUID]) async throws -> [ActivitySession] {
        guard !activityIds.isEmpty else { return [] }
        return try await Supa.client
            .from("activite_seances")
            .select(ActivitySession.columns)
            .in("activite_id", values: activityIds.map(\.uuidString))
            .order("date")
            .order("heure_debut")
            .execute()
            .value
    }

    /// Inscriptions actives lisibles par l'appelant. Pour un membre, la base ne
    /// renvoie que les siennes ; pour un entraîneur, celles de ses cours.
    static func activeEnrollments(activityIds: [UUID]) async throws -> [ActivityEnrollment] {
        guard !activityIds.isEmpty else { return [] }
        return try await Supa.client
            .from("activite_inscriptions")
            .select(ActivityEnrollment.columns)
            .in("activite_id", values: activityIds.map(\.uuidString))
            .in("statut", values: [EnrollmentStatus.inscrit.rawValue, EnrollmentStatus.listeAttente.rawValue])
            .order("inscrit_le")
            .execute()
            .value
    }

    /// Le membre et les enfants dont il est responsable. Tolérant : sans
    /// réponse, on inscrit le membre lui-même.
    static func managedProfiles(clubId: UUID) async -> [ManagedProfile] {
        do {
            let rows: [Lenient<ManagedProfile>] = try await Supa.client
                .rpc("mes_profils_geres", params: ClubParam(targetClubId: clubId))
                .execute()
                .value
            return rows.compactValues()
        } catch {
            return []
        }
    }

    // MARK: - Inscription

    static func enroll(activityId: UUID, forProfileId: UUID?) async throws -> EnrollmentResult {
        do {
            let rows: [EnrollmentResult] = try await Supa.client
                .rpc("inscrire_activite", params: EnrollParams(activiteId: activityId, pourProfileId: forProfileId))
                .execute()
                .value
            guard let result = rows.first else { throw ActivityServiceError.failed }
            return result
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    static func unenroll(inscriptionId: UUID) async throws {
        do {
            try await Supa.client
                .rpc("desinscrire_activite", params: InscriptionParam(inscriptionId: inscriptionId))
                .execute()
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    // MARK: - Paramètres

    private nonisolated struct ClubParam: Encodable, Sendable {
        let targetClubId: UUID
        enum CodingKeys: String, CodingKey { case targetClubId = "target_club_id" }
    }

    private nonisolated struct EnrollParams: Encodable, Sendable {
        let activiteId: UUID
        let pourProfileId: UUID?

        enum CodingKeys: String, CodingKey {
            case activiteId = "p_activite_id"
            case pourProfileId = "p_pour_profile_id"
        }

        // Clé explicite à `null` : c'est ainsi que la fonction comprend
        // « pour moi-même ».
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(activiteId, forKey: .activiteId)
            try c.encode(pourProfileId, forKey: .pourProfileId)
        }
    }

    private nonisolated struct InscriptionParam: Encodable, Sendable {
        let inscriptionId: UUID
        enum CodingKeys: String, CodingKey { case inscriptionId = "p_inscription_id" }
    }
}
