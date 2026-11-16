//
//  ActivityService.swift
//  iClub
//
//  Lecture des activités du club et inscription. Les refus (âge, niveau,
//  inscriptions fermées, complet) arrivent de la base en P0001, avec un message
//  rédigé en français : on le montre tel quel.
//
//  Rôle
//    Lectures de l'onglet « Cours » et de l'espace entraîneur (activités,
//    séances, inscriptions), liste des personnes au nom de qui le membre peut
//    agir (compte famille), inscription et désinscription. Définit aussi
//    `ActivityServiceError`, la traduction d'erreurs partagée par la plupart
//    des services (messagerie, documents, entraîneur, adhésion).
//
//  Place dans l'application
//    `ActivitiesStore`, `ActivityDetailView`, `CoachStore` et les écrans de
//    l'entraîneur, `AttendanceReminders`, `AuthController.reloadFamily`,
//    `ProfileExtrasStore`.
//
//  Tables et fonctions SQL
//    - Tables `activites`, `activite_seances`, `activite_inscriptions` (RLS de
//      la migration `20261018100000_entrainement.sql` : activités et séances
//      lisibles par les membres du club ; inscriptions lisibles par l'inscrit,
//      l'entraîneur de l'activité et l'administration).
//    - `mes_profils_geres(target_club_id)` (migration `20261018160000_comptes_famille.sql`).
//    - `inscrire_activite(p_activite_id, p_pour_profile_id)` (dernière version :
//      `20261018170000_correctif_inscrire_activite.sql`) : droit d'agir pour
//      l'enfant (`peut_agir_pour`), verrou sur l'activité, statut, fenêtre
//      d'inscription, doublon, âge, niveau, places puis liste d'attente ; passe
//      l'activité en `complete` à la dernière place.
//    - `desinscrire_activite(p_inscription_id)` : l'inscrit, son responsable,
//      l'entraîneur ou l'administration ; une place libérée profite au premier
//      de la liste d'attente, sinon l'activité repasse `ouverte`.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Aucun cache.
//

import Foundation
import Supabase

/// Erreurs des services adossés aux fonctions SQL, avec leur message affichable.
enum ActivityServiceError: LocalizedError {
    /// La migration attendue n'est pas passée : fonction inconnue.
    case unavailable
    /// Refus explicite, message prêt à afficher (souvent rédigé par la base).
    case refused(String)
    /// Échec sans explication exploitable (réseau, erreur inattendue).
    case failed

    /// Message montré à l'utilisateur.
    var errorDescription: String? {
        switch self {
        case .unavailable: "Cette fonction n'est pas encore disponible pour votre club."
        case .refused(let message): message
        case .failed: "L'opération n'a pas abouti. Vérifiez votre connexion et réessayez."
        }
    }

    /// Traduit une erreur PostgREST en message lisible.
    ///
    /// Codes reconnus :
    /// - `PGRST202` (fonction introuvable dans le cache de schéma de PostgREST)
    ///   et `42883` (fonction inexistante pour PostgreSQL) : `unavailable` ;
    /// - `P0001` (exception levée par une fonction SQL, code par défaut de
    ///   `raise exception`) : `refused` avec le message de la base ;
    /// - `42501` (droit insuffisant, par exemple une insertion refusée par la
    ///   RLS) : `refused` avec un message générique.
    ///
    /// - Parameter error: erreur quelconque.
    /// - Returns: l'erreur elle-même si c'est déjà une `ActivityServiceError`,
    ///   `failed` pour tout ce qui n'est pas une `PostgrestError` reconnue.
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

/// Reformulation des refus selon le vocabulaire de l'app (cours, événement).
extension ActivityServiceError {
    /// Les messages de la base disent encore « cette activité » : en attendant
    /// la migration du club, on dit « ce cours » ou « cet événement » selon le
    /// type, sans rien changer d'autre au message.
    ///
    /// - Parameter type: type de l'activité concernée.
    /// - Returns: le refus reformulé ; toute autre erreur inchangée.
    func worded(for type: ActivityType) -> ActivityServiceError {
        switch self {
        case .refused(let message):
            let lower = type.demonstrative
            // Même formule avec majuscule, pour un début de phrase.
            let upper = lower.prefix(1).uppercased() + lower.dropFirst()
            return .refused(message
                .replacingOccurrences(of: "cette activité", with: lower)
                .replacingOccurrences(of: "Cette activité", with: upper))
        default:
            return self
        }
    }
}

/// Accès aux cours, séances et inscriptions.
enum ActivityService {

    // MARK: - Lecture

    /// Activités en ligne : ni brouillon, ni proposée, ni annulée, ni terminée.
    /// « Complète » reste visible : la liste d'attente y est encore ouverte.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: activités triées par nom.
    /// - Throws: l'erreur brute de la requête ou du décodage. Le tableau est
    ///   décodé sans `Lenient` : une seule ligne illisible fait échouer toute
    ///   la liste.
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
    /// (Brouillons et propositions en attente du club sont donc inclus.)
    ///
    /// - Parameters:
    ///   - clubId: club de l'entraîneur.
    ///   - coachId: profil de l'entraîneur titulaire.
    /// - Returns: activités triées par nom.
    /// - Throws: l'erreur brute de la requête ou du décodage.
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
    ///
    /// - Parameters:
    ///   - activityIds: activités concernées ; vide, aucune requête n'est faite.
    ///   - day: premier jour inclus (aujourd'hui par défaut, fuseau de l'appareil).
    /// - Returns: séances `prevue` triées par date puis heure de début.
    /// - Throws: l'erreur brute de la requête ou du décodage.
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
    ///
    /// - Parameter activityIds: activités concernées ; vide, aucune requête.
    /// - Returns: séances de tous statuts, triées par date puis heure.
    /// - Throws: l'erreur brute de la requête ou du décodage.
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
    /// (Celles des enfants d'un parent ne sont pas couvertes par la RLS de
    /// lecture et ne remontent donc pas ici.)
    ///
    /// - Parameter activityIds: activités concernées ; vide, aucune requête.
    /// - Returns: inscriptions `inscrit` et `liste_attente`, par date
    ///   d'inscription.
    /// - Throws: l'erreur brute de la requête ou du décodage.
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
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: lui-même en premier (`est_moi`), puis ses enfants ; liste
    ///   vide en cas d'échec.
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

    /// Inscrit le membre, ou un enfant, à une activité.
    ///
    /// - Parameters:
    ///   - activityId: activité visée.
    ///   - forProfileId: enfant à inscrire, ou `nil` pour soi.
    /// - Returns: l'inscription créée, avec son statut (place ou liste
    ///   d'attente) et son rang éventuel.
    /// - Throws: `ActivityServiceError` : refus rédigé de la base (inscriptions
    ///   fermées, déjà inscrit, âge, niveau, complet…), fonction absente, échec.
    static func enroll(activityId: UUID, forProfileId: UUID?) async throws -> EnrollmentResult {
        do {
            // La fonction rend une table : une seule ligne attendue.
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

    /// Annule une inscription (statut `annule`). La base fait monter le premier
    /// de la liste d'attente si une place se libère.
    ///
    /// - Parameter inscriptionId: inscription à annuler.
    /// - Throws: `ActivityServiceError` (« Non autorisé », introuvable, échec).
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

    /// Paramètre de `mes_profils_geres`.
    private nonisolated struct ClubParam: Encodable, Sendable {
        /// `target_club_id`.
        let targetClubId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case targetClubId = "target_club_id" }
    }

    /// Paramètres de `inscrire_activite`.
    private nonisolated struct EnrollParams: Encodable, Sendable {
        /// `p_activite_id`.
        let activiteId: UUID
        /// `p_pour_profile_id` : enfant à inscrire, `nil` pour soi.
        let pourProfileId: UUID?

        /// Noms des paramètres SQL.
        enum CodingKeys: String, CodingKey {
            case activiteId = "p_activite_id"
            case pourProfileId = "p_pour_profile_id"
        }

        // Clé explicite à `null` : c'est ainsi que la fonction comprend
        // « pour moi-même » (elle prend `coalesce(p_pour_profile_id, auth.uid())`).
        // L'encodeur synthétisé omettrait la clé pour une valeur nulle.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(activiteId, forKey: .activiteId)
            try c.encode(pourProfileId, forKey: .pourProfileId)
        }
    }

    /// Paramètre de `desinscrire_activite`.
    private nonisolated struct InscriptionParam: Encodable, Sendable {
        /// `p_inscription_id`.
        let inscriptionId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case inscriptionId = "p_inscription_id" }
    }
}
