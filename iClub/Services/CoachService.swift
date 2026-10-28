//
//  CoachService.swift
//  iClub
//
//  Écritures de l'espace entraîneur. La base vérifie chaque droit
//  (`est_entraineur_du_club`, propriétaire de l'activité) : un refus remonte
//  en clair, jamais en silence.
//

import Foundation
import Supabase

// MARK: - Modèles propres à l'entraîneur

/// État de présence d'un élève à une séance.
nonisolated enum AttendanceState: String, CaseIterable, Sendable, Codable {
    case present, absent, excuse, retard

    var label: String {
        switch self {
        case .present: "Présent"
        case .absent: "Absent"
        case .excuse: "Excusé"
        case .retard: "Retard"
        }
    }

    var symbolName: String {
        switch self {
        case .present: "checkmark"
        case .absent: "xmark"
        case .excuse: "envelope"
        case .retard: "clock"
        }
    }
}

nonisolated struct AttendanceRow: Codable, Sendable {
    let seanceId: UUID
    let inscriptionId: UUID
    let etat: AttendanceState
    var saisiePar: UUID?

    enum CodingKeys: String, CodingKey {
        case etat
        case seanceId = "seance_id"
        case inscriptionId = "inscription_id"
        case saisiePar = "saisie_par"
    }
}

/// Un créneau que le club a alloué à l'entraîneur (`creneaux_entraineur`).
/// Un cours posé dedans part directement en ligne.
nonisolated struct CoachSlot: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let courtId: UUID?
    let sport: Sport
    let jourSemaine: Int
    let startMinutes: Int
    let endMinutes: Int
    let dateDebut: Date
    let dateFin: Date

    enum CodingKeys: String, CodingKey {
        case id, sport
        case courtId = "court_id"
        case jourSemaine = "jour_semaine"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case dateDebut = "date_debut"
        case dateFin = "date_fin"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        courtId = try c.decodeIfPresent(UUID.self, forKey: .courtId)
        sport = (try? c.decode(Sport.self, forKey: .sport)) ?? .tennis
        jourSemaine = try c.decode(Int.self, forKey: .jourSemaine)
        startMinutes = PostgresTime.minutes(from: try c.decode(String.self, forKey: .heureDebut)) ?? 0
        endMinutes = PostgresTime.minutes(from: try c.decode(String.self, forKey: .heureFin)) ?? 0
        dateDebut = SupabaseDate.parse(try c.decode(String.self, forKey: .dateDebut)) ?? .now
        dateFin = SupabaseDate.parse(try c.decode(String.self, forKey: .dateFin)) ?? .now
    }
}

/// Retour de `creer_activite`.
nonisolated struct CourseCreationResult: Hashable, Sendable, Decodable {
    let activiteId: UUID
    let statut: ActivityStatus
    let seancesCreees: Int
    let datesEnConflit: [Date]

    enum CodingKeys: String, CodingKey {
        case statut
        case activiteId = "activite_id"
        case seancesCreees = "seances_creees"
        case datesEnConflit = "dates_en_conflit"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activiteId = try c.decode(UUID.self, forKey: .activiteId)
        statut = (try? c.decode(ActivityStatus.self, forKey: .statut)) ?? .proposee
        seancesCreees = try c.decodeIfPresent(Int.self, forKey: .seancesCreees) ?? 0
        let raw = try c.decodeIfPresent([String].self, forKey: .datesEnConflit) ?? []
        datesEnConflit = raw.compactMap { SupabaseDate.parse($0) }
    }
}

/// Saisie du formulaire de création d'un cours.
struct CourseDraft {
    var type: ActivityType = .collectif
    var sport: Sport = .tennis
    var nom = ""
    var courtId: UUID?
    /// Lundi = 1 … dimanche = 7, comme `p_jour_semaine`.
    var jourSemaine = 3
    var startMinutes = 17 * 60
    var endMinutes = 18 * 60
    var dateDebut = Date.now
    var dateFin = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now
    var placesMax = 6
    var description = ""
    var niveauMin: String?
    var niveauMax: String?
    var ageMin: Int?
    var ageMax: Int?
    var tarifLibelle = ""

    /// Leçon individuelle : une place ; en duo : deux.
    var effectivePlaces: Int {
        switch type {
        case .individuel: 1
        case .duo: 2
        default: placesMax
        }
    }

    var isValid: Bool {
        !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && courtId != nil
            && endMinutes > startMinutes
            && Calendar.current.startOfDay(for: dateFin) >= Calendar.current.startOfDay(for: dateDebut)
    }

    mutating func apply(_ slot: CoachSlot, fallbackCourt: UUID?) {
        sport = slot.sport
        courtId = slot.courtId ?? fallbackCourt
        jourSemaine = slot.jourSemaine
        startMinutes = slot.startMinutes
        endMinutes = slot.endMinutes
        dateDebut = max(slot.dateDebut, Calendar.current.startOfDay(for: .now))
        dateFin = slot.dateFin
    }
}

enum CoachService {

    // MARK: - Lecture

    static func coachSlots(clubId: UUID, coachId: UUID) async -> [CoachSlot] {
        (try? await Supa.client
            .from("creneaux_entraineur")
            .select("id, court_id, sport, jour_semaine, heure_debut, heure_fin, date_debut, date_fin")
            .eq("club_id", value: clubId.uuidString)
            .eq("entraineur_profile_id", value: coachId.uuidString)
            .eq("actif", value: true)
            .gte("date_fin", value: SupabaseDate.day(from: .now))
            .order("jour_semaine")
            .order("heure_debut")
            .execute()
            .value) ?? []
    }

    static func attendance(sessionId: UUID) async throws -> [AttendanceRow] {
        try await Supa.client
            .from("activite_presences")
            .select("seance_id, inscription_id, etat, saisie_par")
            .eq("seance_id", value: sessionId.uuidString)
            .execute()
            .value
    }

    /// Toutes les présences pointées pour un élève, toutes séances confondues.
    static func attendanceHistory(inscriptionId: UUID) async throws -> [AttendanceRow] {
        try await Supa.client
            .from("activite_presences")
            .select("seance_id, inscription_id, etat, saisie_par")
            .eq("inscription_id", value: inscriptionId.uuidString)
            .execute()
            .value
    }

    // MARK: - Appel

    /// Un tap, une écriture : upsert sur la paire (séance, inscription).
    static func setAttendance(_ rows: [AttendanceRow]) async throws {
        guard !rows.isEmpty else { return }
        do {
            let written: [AttendanceRow] = try await Supa.client
                .from("activite_presences")
                .upsert(rows, onConflict: "seance_id,inscription_id")
                .select("seance_id, inscription_id, etat, saisie_par")
                .execute()
                .value
            guard written.count == rows.count else { throw refusedWrite }
        } catch {
            throw mapped(error)
        }
    }

    /// Séance passée en « faite » une fois l'appel complet.
    static func markSessionDone(_ sessionId: UUID) async throws {
        try await updateSession(sessionId, SessionStatusUpdate(statut: SessionStatus.faite.rawValue), onlyIfPlanned: true)
    }

    /// Note sur le groupe, jamais sur un élève.
    static func saveNote(_ note: String, sessionId: UUID) async throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try await updateSession(sessionId, SessionNoteUpdate(noteSeance: trimmed.isEmpty ? nil : trimmed), onlyIfPlanned: false)
    }

    /// Annulation avec motif. Passe par `annuler_seance`, qui rend aussi le
    /// terrain : l'entraîneur n'a pas le droit d'écrire dans `slot_overrides`.
    static func cancelSession(_ sessionId: UUID, motif: String) async throws {
        do {
            try await Supa.client
                .rpc("annuler_seance", params: CancelParams(seanceId: sessionId, motif: motif))
                .execute()
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Création

    static func createCourse(_ draft: CourseDraft, clubId: UUID) async throws -> CourseCreationResult {
        guard let courtId = draft.courtId else { throw ActivityServiceError.refused("Choisissez un terrain.") }
        let params = CreateParams(
            clubId: clubId,
            type: draft.type.rawValue,
            sport: draft.sport.rawValue,
            nom: draft.nom.trimmingCharacters(in: .whitespaces),
            courtId: courtId,
            jourSemaine: draft.jourSemaine,
            heureDebut: PostgresTime.string(draft.startMinutes),
            heureFin: PostgresTime.string(draft.endMinutes),
            dateDebut: SupabaseDate.day(from: draft.dateDebut),
            dateFin: SupabaseDate.day(from: draft.dateFin),
            placesMax: draft.effectivePlaces,
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            niveauMin: draft.niveauMin,
            niveauMax: draft.niveauMax,
            ageMin: draft.ageMin,
            ageMax: draft.ageMax,
            tarifLibelle: draft.tarifLibelle.trimmingCharacters(in: .whitespaces).nilIfEmpty
        )

        do {
            let rows: [CourseCreationResult] = try await Supa.client
                .rpc("creer_activite", params: params)
                .execute()
                .value
            guard let result = rows.first else { throw ActivityServiceError.failed }
            return result
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Outils

    private static var refusedWrite: ActivityServiceError {
        .refused("La base a refusé cette modification : vous ne pouvez agir que sur vos propres cours.")
    }

    private static func mapped(_ error: Error) -> ActivityServiceError {
        ActivityServiceError.from(error)
    }

    private static func updateSession(_ id: UUID, _ payload: some Encodable & Sendable, onlyIfPlanned: Bool) async throws {
        do {
            var query = try Supa.client
                .from("activite_seances")
                .update(payload)
                .eq("id", value: id.uuidString)
            if onlyIfPlanned { query = query.eq("statut", value: SessionStatus.prevue.rawValue) }

            let rows: [IdRow] = try await query.select("id").execute().value
            // Déjà « faite » : rien à changer, ce n'est pas un refus.
            if rows.isEmpty && !onlyIfPlanned { throw refusedWrite }
        } catch {
            throw mapped(error)
        }
    }

    private nonisolated struct IdRow: Decodable, Sendable { let id: UUID }

    private nonisolated struct SessionStatusUpdate: Encodable, Sendable {
        let statut: String
    }

    private nonisolated struct SessionNoteUpdate: Encodable, Sendable {
        let noteSeance: String?
        enum CodingKeys: String, CodingKey { case noteSeance = "note_seance" }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(noteSeance, forKey: .noteSeance)
        }
    }

    private nonisolated struct CancelParams: Encodable, Sendable {
        let seanceId: UUID
        let motif: String
        enum CodingKeys: String, CodingKey {
            case seanceId = "p_seance_id"
            case motif = "p_motif"
        }
    }

    private nonisolated struct CreateParams: Encodable, Sendable {
        let clubId: UUID
        let type: String
        let sport: String
        let nom: String
        let courtId: UUID
        let jourSemaine: Int
        let heureDebut: String
        let heureFin: String
        let dateDebut: String
        let dateFin: String
        let placesMax: Int
        let description: String?
        let niveauMin: String?
        let niveauMax: String?
        let ageMin: Int?
        let ageMax: Int?
        let tarifLibelle: String?

        enum CodingKeys: String, CodingKey {
            case clubId = "p_club_id"
            case type = "p_type"
            case sport = "p_sport"
            case nom = "p_nom"
            case courtId = "p_court_id"
            case jourSemaine = "p_jour_semaine"
            case heureDebut = "p_heure_debut"
            case heureFin = "p_heure_fin"
            case dateDebut = "p_date_debut"
            case dateFin = "p_date_fin"
            case placesMax = "p_places_max"
            case description = "p_description"
            case niveauMin = "p_niveau_min"
            case niveauMax = "p_niveau_max"
            case ageMin = "p_age_min"
            case ageMax = "p_age_max"
            case tarifLibelle = "p_tarif_libelle"
        }

        // Toutes les clés, `null` compris : PostgREST choisit la fonction sur
        // l'ensemble des noms de paramètres.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(clubId, forKey: .clubId)
            try c.encode(type, forKey: .type)
            try c.encode(sport, forKey: .sport)
            try c.encode(nom, forKey: .nom)
            try c.encode(courtId, forKey: .courtId)
            try c.encode(jourSemaine, forKey: .jourSemaine)
            try c.encode(heureDebut, forKey: .heureDebut)
            try c.encode(heureFin, forKey: .heureFin)
            try c.encode(dateDebut, forKey: .dateDebut)
            try c.encode(dateFin, forKey: .dateFin)
            try c.encode(placesMax, forKey: .placesMax)
            try c.encode(description, forKey: .description)
            try c.encode(niveauMin, forKey: .niveauMin)
            try c.encode(niveauMax, forKey: .niveauMax)
            try c.encode(ageMin, forKey: .ageMin)
            try c.encode(ageMax, forKey: .ageMax)
            try c.encode(tarifLibelle, forKey: .tarifLibelle)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
