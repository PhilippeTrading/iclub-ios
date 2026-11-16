//
//  CoachService.swift
//  iClub
//
//  Écritures de l'espace entraîneur. La base vérifie chaque droit
//  (`est_entraineur_du_club`, propriétaire de l'activité) : un refus remonte
//  en clair, jamais en silence.
//
//  Rôle
//    Créneaux alloués à l'entraîneur, appel (présences), statut et note des
//    séances, annulation d'une séance, création d'un cours. Déclare aussi les
//    modèles propres à l'entraîneur (présence, créneau alloué, brouillon de
//    cours).
//
//  Place dans l'application
//    Espace entraîneur de l'onglet « Cours » : `CoachStore` (créneaux),
//    `AttendanceView` (appel, note, séance faite), `CoachCourseView`
//    (annulation), `CreateCourseView` (création), `StudentViews` (historique
//    de présence d'un élève).
//
//  Tables et fonctions SQL (migrations `20261018100000_entrainement.sql`,
//  `20261018160000_comptes_famille.sql`, `20261023120000_vacances_scolaires.sql`)
//    - `creneaux_entraineur` : lisible par les membres du club, écrite par
//      l'administration.
//    - `activite_presences` : lue par l'élève, l'entraîneur de l'activité et
//      l'administration ; écrite par l'entraîneur et l'administration ;
//      unicité (séance, inscription).
//    - `activite_seances` : écrite par l'entraîneur de l'activité et
//      l'administration.
//    - `annuler_seance(p_seance_id, p_motif)` : annule la séance et retire son
//      blocage de terrain.
//    - `creer_activite(...)` : crée le cours et ses séances (voir `createCourse`).
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Aucun cache.
//

import Foundation
import Supabase

// MARK: - Modèles propres à l'entraîneur

/// État de présence d'un élève à une séance.
/// (Valeurs de `activite_presences.etat`.)
nonisolated enum AttendanceState: String, CaseIterable, Sendable, Codable {
    /// Présent, absent, excusé, en retard.
    case present, absent, excuse, retard

    /// Libellé du bouton de pointage.
    var label: String {
        switch self {
        case .present: "Présent"
        case .absent: "Absent"
        case .excuse: "Excusé"
        case .retard: "Retard"
        }
    }

    /// Pictogramme SF Symbols du bouton.
    var symbolName: String {
        switch self {
        case .present: "checkmark"
        case .absent: "xmark"
        case .excuse: "envelope"
        case .retard: "clock"
        }
    }
}

/// Ligne de `activite_presences`, lue et écrite telle quelle.
nonisolated struct AttendanceRow: Codable, Sendable {
    /// `seance_id`.
    let seanceId: UUID
    /// `inscription_id` : l'élève, par son inscription.
    let inscriptionId: UUID
    /// `etat`.
    let etat: AttendanceState
    /// `saisie_par` : profil qui a pointé. Optionnel ; encodage synthétisé, donc
    /// clé omise quand la valeur est nulle.
    var saisiePar: UUID?

    /// Correspondance avec les colonnes SQL.
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
    /// `id`.
    let id: UUID
    /// `court_id` : terrain imposé, `nil` pour n'importe quel terrain du sport.
    let courtId: UUID?
    /// `sport`, `tennis` si la valeur est inconnue.
    let sport: Sport
    /// `jour_semaine` : lundi = 1 … dimanche = 7.
    let jourSemaine: Int
    /// `heure_debut`, en minutes depuis minuit (0 si illisible).
    let startMinutes: Int
    /// `heure_fin`, en minutes depuis minuit (0 si illisible).
    let endMinutes: Int
    /// `date_debut` : première date de validité de l'allocation.
    let dateDebut: Date
    /// `date_fin` : dernière date de validité.
    let dateFin: Date

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, sport
        case courtId = "court_id"
        case jourSemaine = "jour_semaine"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case dateDebut = "date_debut"
        case dateFin = "date_fin"
    }

    /// Décodage : identifiant, jour, heures et dates obligatoires en base ; une
    /// date illisible devient aujourd'hui.
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
///
/// La fonction rend aussi `dates_vacances` (dates écartées pour vacances
/// scolaires), non décodé : l'app ne demande jamais la suspension.
nonisolated struct CourseCreationResult: Hashable, Sendable, Decodable {
    /// `activite_id` : activité créée.
    let activiteId: UUID
    /// `statut` : `ouverte` (dans l'enveloppe allouée, ou créée par un
    /// administrateur) ou `proposee` (en attente du club).
    let statut: ActivityStatus
    /// `seances_creees` : nombre de séances posées.
    let seancesCreees: Int
    /// `dates_en_conflit` : dates sans séance, parce qu'une réservation ou un
    /// blocage occupait déjà le terrain.
    let datesEnConflit: [Date]

    /// Correspondance avec les colonnes rendues par la fonction.
    enum CodingKeys: String, CodingKey {
        case statut
        case activiteId = "activite_id"
        case seancesCreees = "seances_creees"
        case datesEnConflit = "dates_en_conflit"
    }

    /// Décodage tolérant : seul l'identifiant est obligatoire ; les dates
    /// (`date[]`) arrivent en texte.
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
    /// Type de cours, collectif par défaut.
    var type: ActivityType = .collectif
    /// Sport, tennis par défaut.
    var sport: Sport = .tennis
    /// Intitulé du cours.
    var nom = ""
    /// Terrain, obligatoire avant l'envoi.
    var courtId: UUID?
    /// Lundi = 1 … dimanche = 7, comme `p_jour_semaine`.
    /// (3 par défaut : le mercredi.)
    var jourSemaine = 3
    /// Début de chaque séance, en minutes depuis minuit (17 h par défaut).
    var startMinutes = 17 * 60
    /// Fin de chaque séance, en minutes depuis minuit (18 h par défaut).
    var endMinutes = 18 * 60
    /// Premier jour de la période (aujourd'hui par défaut).
    var dateDebut = Date.now
    /// Dernier jour de la période (dans trois mois par défaut).
    var dateFin = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now
    /// Places d'un cours collectif ou d'un stage (6 par défaut).
    var placesMax = 6
    /// Présentation libre.
    var description = ""
    /// Niveau minimal demandé, classement stocké ; `nil` pour aucun.
    var niveauMin: String?
    /// Niveau maximal demandé ; `nil` pour aucun.
    var niveauMax: String?
    /// Âge minimal ; `nil` pour aucun.
    var ageMin: Int?
    /// Âge maximal ; `nil` pour aucun.
    var ageMax: Int?
    /// Tarif en texte libre (« 120 € la saison »), facultatif.
    var tarifLibelle = ""

    /// Leçon individuelle : une place ; en duo : deux.
    /// Sinon la valeur saisie.
    var effectivePlaces: Int {
        switch type {
        case .individuel: 1
        case .duo: 2
        default: placesMax
        }
    }

    /// Le formulaire peut être envoyé : intitulé non vide, terrain choisi, fin
    /// après le début, période non inversée (comparée jour à jour).
    var isValid: Bool {
        !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && courtId != nil
            && endMinutes > startMinutes
            && Calendar.current.startOfDay(for: dateFin) >= Calendar.current.startOfDay(for: dateDebut)
    }

    /// Préremplit le formulaire avec un créneau alloué.
    ///
    /// - Parameters:
    ///   - slot: créneau alloué choisi.
    ///   - fallbackCourt: terrain retenu si l'allocation n'en impose pas (le
    ///     premier terrain du sport, côté appelant).
    mutating func apply(_ slot: CoachSlot, fallbackCourt: UUID?) {
        sport = slot.sport
        courtId = slot.courtId ?? fallbackCourt
        jourSemaine = slot.jourSemaine
        startMinutes = slot.startMinutes
        endMinutes = slot.endMinutes
        // Une allocation commencée dans le passé : le cours démarre aujourd'hui.
        dateDebut = max(slot.dateDebut, Calendar.current.startOfDay(for: .now))
        dateFin = slot.dateFin
    }
}

/// Écritures et lectures de l'espace entraîneur.
enum CoachService {

    // MARK: - Lecture

    /// Créneaux alloués encore valables (fin au plus tôt aujourd'hui).
    ///
    /// - Parameters:
    ///   - clubId: club de l'entraîneur.
    ///   - coachId: profil de l'entraîneur.
    /// - Returns: créneaux actifs triés par jour puis heure ; liste vide en cas
    ///   d'échec.
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

    /// Présences déjà pointées pour une séance.
    ///
    /// - Parameter sessionId: séance.
    /// - Returns: une ligne par élève pointé.
    /// - Throws: l'erreur brute de la requête.
    static func attendance(sessionId: UUID) async throws -> [AttendanceRow] {
        try await Supa.client
            .from("activite_presences")
            .select("seance_id, inscription_id, etat, saisie_par")
            .eq("seance_id", value: sessionId.uuidString)
            .execute()
            .value
    }

    /// Toutes les présences pointées pour un élève, toutes séances confondues.
    ///
    /// - Parameter inscriptionId: inscription de l'élève.
    /// - Returns: une ligne par séance pointée.
    /// - Throws: l'erreur brute de la requête.
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
    ///
    /// - Parameter rows: présences à écrire ; vide, rien n'est envoyé.
    /// - Throws: `ActivityServiceError.refused` si la base n'a pas écrit toutes
    ///   les lignes (droits), ou une erreur traduite.
    static func setAttendance(_ rows: [AttendanceRow]) async throws {
        guard !rows.isEmpty else { return }
        do {
            // Contrainte d'unicité (seance_id, inscription_id) : une présence
            // existante est remplacée, sinon créée.
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
    ///
    /// - Parameter sessionId: séance.
    /// - Throws: une erreur traduite. Une séance qui n'est plus « prévue » n'est
    ///   pas modifiée, sans erreur.
    static func markSessionDone(_ sessionId: UUID) async throws {
        try await updateSession(sessionId, SessionStatusUpdate(statut: SessionStatus.faite.rawValue), onlyIfPlanned: true)
    }

    /// Note sur le groupe, jamais sur un élève.
    ///
    /// - Parameters:
    ///   - note: texte saisi ; vide après nettoyage, la note est effacée.
    ///   - sessionId: séance.
    /// - Throws: `ActivityServiceError.refused` si aucune ligne n'a été
    ///   modifiée, ou une erreur traduite.
    static func saveNote(_ note: String, sessionId: UUID) async throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try await updateSession(sessionId, SessionNoteUpdate(noteSeance: trimmed.isEmpty ? nil : trimmed), onlyIfPlanned: false)
    }

    /// Annulation avec motif. Passe par `annuler_seance`, qui rend aussi le
    /// terrain : l'entraîneur n'a pas le droit d'écrire dans `slot_overrides`.
    ///
    /// - Parameters:
    ///   - sessionId: séance à annuler.
    ///   - motif: motif affiché aux élèves.
    /// - Throws: une erreur traduite (« Non autorisé », séance introuvable…).
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

    /// Crée un cours et ses séances (fonction `creer_activite`).
    ///
    /// La fonction réserve le droit aux entraîneurs du club et à
    /// l'administration ; vérifie heures, période et terrain ; met le cours en
    /// ligne s'il tient dans un créneau alloué (ou si l'auteur est
    /// administrateur), et pose alors un blocage de terrain par séance ; sinon
    /// le cours part « proposé », sans bloquer le terrain. Les dates déjà
    /// occupées sont sautées et rendues dans `datesEnConflit`.
    ///
    /// - Parameters:
    ///   - draft: saisie du formulaire.
    ///   - clubId: club de l'entraîneur.
    /// - Returns: le résultat de la création.
    /// - Throws: `ActivityServiceError.refused` (« Choisissez un terrain. », ou
    ///   refus rédigé de la base) ou une autre erreur traduite.
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
            // La fonction rend une table d'une ligne.
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

    /// Refus générique d'une écriture qui n'a touché aucune ligne.
    private static var refusedWrite: ActivityServiceError {
        .refused("La base a refusé cette modification : vous ne pouvez agir que sur vos propres cours.")
    }

    /// Traduction commune des erreurs (voir `ActivityServiceError.from`).
    ///
    /// - Parameter error: erreur quelconque.
    /// - Returns: l'erreur affichable.
    private static func mapped(_ error: Error) -> ActivityServiceError {
        ActivityServiceError.from(error)
    }

    /// Met à jour une séance et vérifie qu'une ligne a été touchée.
    ///
    /// - Parameters:
    ///   - id: séance.
    ///   - payload: colonnes à écrire.
    ///   - onlyIfPlanned: n'agir que sur une séance encore « prévue » ; dans ce
    ///     cas, aucune ligne touchée n'est pas une erreur.
    /// - Throws: `refusedWrite` (aucune ligne, hors `onlyIfPlanned`) ou une
    ///   erreur traduite.
    ///
    /// Attention : avec `onlyIfPlanned`, un refus de la RLS passe aussi sans
    /// erreur, faute de pouvoir le distinguer d'une séance déjà « faite ».
    private static func updateSession(_ id: UUID, _ payload: some Encodable & Sendable, onlyIfPlanned: Bool) async throws {
        do {
            var query = try Supa.client
                .from("activite_seances")
                .update(payload)
                .eq("id", value: id.uuidString)
            if onlyIfPlanned { query = query.eq("statut", value: SessionStatus.prevue.rawValue) }

            // `.select("id")` : les lignes réellement modifiées.
            let rows: [IdRow] = try await query.select("id").execute().value
            // Déjà « faite » : rien à changer, ce n'est pas un refus.
            if rows.isEmpty && !onlyIfPlanned { throw refusedWrite }
        } catch {
            throw mapped(error)
        }
    }

    /// Ligne rendue par `.select("id")`.
    private nonisolated struct IdRow: Decodable, Sendable { let id: UUID }

    /// Charge utile `{ "statut": … }`.
    private nonisolated struct SessionStatusUpdate: Encodable, Sendable {
        /// `activite_seances.statut`.
        let statut: String
    }

    /// Charge utile `{ "note_seance": … }`, `null` compris.
    private nonisolated struct SessionNoteUpdate: Encodable, Sendable {
        /// `note_seance`, `nil` pour effacer.
        let noteSeance: String?
        /// Nom de la colonne SQL.
        enum CodingKeys: String, CodingKey { case noteSeance = "note_seance" }
        /// Écrit la clé même nulle, pour effacer la note.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(noteSeance, forKey: .noteSeance)
        }
    }

    /// Paramètres de `annuler_seance`.
    private nonisolated struct CancelParams: Encodable, Sendable {
        /// `p_seance_id`.
        let seanceId: UUID
        /// `p_motif` (« Séance annulée » côté base s'il était nul).
        let motif: String
        /// Noms des paramètres SQL.
        enum CodingKeys: String, CodingKey {
            case seanceId = "p_seance_id"
            case motif = "p_motif"
        }
    }

    /// Paramètres de `creer_activite`. `p_suspendre_vacances` n'est pas envoyé :
    /// la fonction prend sa valeur par défaut (`false`).
    private nonisolated struct CreateParams: Encodable, Sendable {
        /// `p_club_id`.
        let clubId: UUID
        /// `p_type` : valeur brute d'`ActivityType`.
        let type: String
        /// `p_sport`.
        let sport: String
        /// `p_nom`.
        let nom: String
        /// `p_court_id`.
        let courtId: UUID
        /// `p_jour_semaine` : lundi = 1 … dimanche = 7.
        let jourSemaine: Int
        /// `p_heure_debut` : « HH:MM:00 ».
        let heureDebut: String
        /// `p_heure_fin` : « HH:MM:00 ».
        let heureFin: String
        /// `p_date_debut` : « AAAA-MM-JJ ».
        let dateDebut: String
        /// `p_date_fin` : « AAAA-MM-JJ ».
        let dateFin: String
        /// `p_places_max`.
        let placesMax: Int
        /// `p_description`, `nil` si vide.
        let description: String?
        /// `p_niveau_min`.
        let niveauMin: String?
        /// `p_niveau_max`.
        let niveauMax: String?
        /// `p_age_min`.
        let ageMin: Int?
        /// `p_age_max`.
        let ageMax: Int?
        /// `p_tarif_libelle`, `nil` si vide.
        let tarifLibelle: String?

        /// Noms des paramètres SQL.
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

/// Outil de saisie : une chaîne vide devient `nil` avant l'envoi à la base.
/// Extension globale, visible dans tout le module.
extension String {
    /// La chaîne elle-même, ou `nil` si elle est vide (sans nettoyage : à
    /// appeler après `trimmingCharacters`).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
