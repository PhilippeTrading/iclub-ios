//
//  Activity.swift
//  iClub
//
//  Ce que le club organise : cours collectifs, stages, leçons, événements,
//  tournois, animations. Tables `activites`, `activite_seances`,
//  `activite_inscriptions`, partagées avec le web.
//
//  Toutes les règles (âge, niveau, places, fenêtre d'inscription, liste
//  d'attente) vivent en base : l'app affiche, elle ne recalcule rien.
//

import Foundation

// MARK: - Heures

/// Colonne `time` → minutes depuis minuit. Isolé de l'acteur principal : les
/// lignes sont décodées en arrière-plan.
nonisolated enum PostgresTime {
    static func minutes(from value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// « 14:00:00 », format d'écriture d'une colonne `time`.
    static func string(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }
}

// MARK: - Type

nonisolated enum ActivityType: String, CaseIterable, Sendable, Codable {
    case collectif, stage, individuel, duo, evenement, tournoi, animation

    /// Groupes de la liste, dans l'ordre, avec les intitulés du web.
    static let displayGroups: [(title: String, types: [ActivityType])] = [
        ("Cours collectifs", [.collectif]),
        ("Leçons", [.individuel, .duo]),
        ("Stages", [.stage]),
        ("Événements", [.evenement, .tournoi, .animation]),
    ]

    // MARK: Vocabulaire (aligné sur le web, 28 octobre 2026)
    //
    // « Cours » : ce à quoi on s'inscrit pour une saison ou un stage.
    // « Événement » : ce qui a lieu une fois.
    // « Séance » : une date précise de l'un ou de l'autre.
    // Le mot « activité » ne s'affiche jamais : il ne reste que dans les noms
    // techniques des tables.

    /// Événement, tournoi, animation : ce qui a lieu une fois.
    var isEvent: Bool {
        switch self {
        case .evenement, .tournoi, .animation: true
        default: false
        }
    }

    /// « Cours » ou « Événement », pour le badge de type.
    var categoryLabel: String { isEvent ? "Événement" : "Cours" }

    /// « ce cours » ou « cet événement ».
    var demonstrative: String { isEvent ? "cet événement" : "ce cours" }

    var singularLabel: String {
        switch self {
        case .collectif: "Cours collectif"
        case .stage: "Stage"
        case .individuel: "Leçon individuelle"
        case .duo: "Leçon en duo"
        case .evenement: "Événement"
        case .tournoi: "Tournoi"
        case .animation: "Animation"
        }
    }

    var symbolName: String {
        switch self {
        case .collectif: "person.3.fill"
        case .stage: "sun.max.fill"
        case .individuel: "person.fill"
        case .duo: "person.2.fill"
        case .evenement: "star.fill"
        case .tournoi: "trophy.fill"
        case .animation: "party.popper.fill"
        }
    }
}

// MARK: - Statut

nonisolated enum ActivityStatus: String, Sendable, Codable {
    case brouillon, proposee, ouverte, complete, terminee, annulee

    var label: String {
        switch self {
        case .brouillon: "Brouillon"
        case .proposee: "En attente du club"
        case .ouverte: "En ligne"
        case .complete: "Complet"
        case .terminee: "Terminé"
        case .annulee: "Annulé"
        }
    }
}

// MARK: - Activité

nonisolated struct Activity: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let clubId: UUID
    let nom: String
    let type: ActivityType
    let sport: Sport
    let description: String?
    /// Colonnes d'origine, texte libre : « Mercredi », « 14h00 ».
    let jour: String?
    let heure: String?
    let courtId: UUID?
    let entraineurProfileId: UUID?
    let encadrantNom: String?
    let niveauMin: String?
    let niveauMax: String?
    let ageMin: Int?
    let ageMax: Int?
    let placesMax: Int
    let listeAttenteMax: Int
    let tarif: Double?
    let tarifLibelle: String?
    let dateDebut: Date?
    let dateFin: Date?
    let inscriptionsOuvertesDu: Date?
    let inscriptionsOuvertesAu: Date?
    let lieu: String?
    let inscritsMin: Int?
    let statut: ActivityStatus

    static let columns = """
        id, club_id, nom, type, sport, description, jour, heure, court_id, \
        entraineur_profile_id, encadrant_nom, niveau_min, niveau_max, age_min, age_max, \
        places_max, liste_attente_max, tarif, tarif_libelle, date_debut, date_fin, \
        inscriptions_ouvertes_du, inscriptions_ouvertes_au, lieu, inscrits_min, statut
        """

    enum CodingKeys: String, CodingKey {
        case id, nom, type, sport, description, jour, heure, tarif, lieu, statut
        case clubId = "club_id"
        case courtId = "court_id"
        case entraineurProfileId = "entraineur_profile_id"
        case encadrantNom = "encadrant_nom"
        case niveauMin = "niveau_min"
        case niveauMax = "niveau_max"
        case ageMin = "age_min"
        case ageMax = "age_max"
        case placesMax = "places_max"
        case listeAttenteMax = "liste_attente_max"
        case tarifLibelle = "tarif_libelle"
        case dateDebut = "date_debut"
        case dateFin = "date_fin"
        case inscriptionsOuvertesDu = "inscriptions_ouvertes_du"
        case inscriptionsOuvertesAu = "inscriptions_ouvertes_au"
        case inscritsMin = "inscrits_min"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clubId = try c.decode(UUID.self, forKey: .clubId)
        nom = try c.decode(String.self, forKey: .nom)
        // Un type ou un statut inconnu (ajouté côté web plus tard) ne doit pas
        // faire disparaître l'activité : on retombe sur la valeur la plus neutre.
        type = (try? c.decode(ActivityType.self, forKey: .type)) ?? .collectif
        sport = (try? c.decode(Sport.self, forKey: .sport)) ?? .tennis
        statut = (try? c.decode(ActivityStatus.self, forKey: .statut)) ?? .ouverte
        description = try c.decodeIfPresent(String.self, forKey: .description)
        jour = try c.decodeIfPresent(String.self, forKey: .jour)
        heure = try c.decodeIfPresent(String.self, forKey: .heure)
        courtId = try c.decodeIfPresent(UUID.self, forKey: .courtId)
        entraineurProfileId = try c.decodeIfPresent(UUID.self, forKey: .entraineurProfileId)
        encadrantNom = try c.decodeIfPresent(String.self, forKey: .encadrantNom)
        niveauMin = try c.decodeIfPresent(String.self, forKey: .niveauMin)
        niveauMax = try c.decodeIfPresent(String.self, forKey: .niveauMax)
        ageMin = try c.decodeIfPresent(Int.self, forKey: .ageMin)
        ageMax = try c.decodeIfPresent(Int.self, forKey: .ageMax)
        placesMax = try c.decodeIfPresent(Int.self, forKey: .placesMax) ?? 0
        listeAttenteMax = try c.decodeIfPresent(Int.self, forKey: .listeAttenteMax) ?? 0
        tarif = try c.decodeIfPresent(Double.self, forKey: .tarif)
        tarifLibelle = try c.decodeIfPresent(String.self, forKey: .tarifLibelle)
        dateDebut = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .dateDebut))
        dateFin = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .dateFin))
        inscriptionsOuvertesDu = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .inscriptionsOuvertesDu))
        inscriptionsOuvertesAu = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .inscriptionsOuvertesAu))
        lieu = try c.decodeIfPresent(String.self, forKey: .lieu)
        inscritsMin = try c.decodeIfPresent(Int.self, forKey: .inscritsMin)
    }

    /// « Mercredi · 14h00 ».
    var usualSchedule: String? {
        let parts = [jour, heure].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « 8 à 14 ans », « 12 ans et plus »…
    var ageLabel: String? {
        switch (ageMin, ageMax) {
        case let (min?, max?): "\(min) à \(max) ans"
        case let (min?, nil): "\(min) ans et plus"
        case let (nil, max?): "Jusqu'à \(max) ans"
        default: nil
        }
    }

    /// « Niveau 30/4 – 15/2 ». Le niveau padel s'écrit avec une virgule.
    var levelLabel: String? {
        func display(_ value: String) -> String {
            sport == .padel ? value.replacingOccurrences(of: ".", with: ",") : value
        }
        switch (niveauMin, niveauMax) {
        case let (min?, max?): return "Niveau \(display(min)) – \(display(max))"
        case let (min?, nil): return "Niveau \(display(min)) minimum"
        case let (nil, max?): return "Niveau \(display(max)) maximum"
        default: return nil
        }
    }

    /// Tarif indicatif : libellé libre d'abord, montant sinon.
    var priceLabel: String? {
        if let tarifLibelle, !tarifLibelle.trimmingCharacters(in: .whitespaces).isEmpty { return tarifLibelle }
        guard let tarif else { return nil }
        return tarif.formatted(.currency(code: "EUR").locale(AppLocale.french))
    }

    var isFull: Bool { statut == .complete }
}

// MARK: - Séance

nonisolated enum SessionStatus: String, Sendable, Codable {
    case prevue, faite, annulee, reportee

    var label: String {
        switch self {
        case .prevue: "Prévue"
        case .faite: "Faite"
        case .annulee: "Annulée"
        case .reportee: "Reportée"
        }
    }
}

nonisolated struct ActivitySession: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let activiteId: UUID
    let date: Date
    let slot: TimeSlot
    let courtId: UUID?
    /// Remplaçant ponctuel ; `nil` = l'entraîneur habituel.
    let entraineurProfileId: UUID?
    let statut: SessionStatus
    let motifAnnulation: String?
    let noteSeance: String?

    static let columns = "id, activite_id, date, heure_debut, heure_fin, court_id, entraineur_profile_id, statut, motif_annulation, note_seance"

    enum CodingKeys: String, CodingKey {
        case id, date, statut
        case activiteId = "activite_id"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case courtId = "court_id"
        case entraineurProfileId = "entraineur_profile_id"
        case motifAnnulation = "motif_annulation"
        case noteSeance = "note_seance"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        activiteId = try c.decode(UUID.self, forKey: .activiteId)
        guard let day = SupabaseDate.parse(try c.decode(String.self, forKey: .date)) else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "date illisible")
        }
        date = day
        let start = PostgresTime.minutes(from: try c.decodeIfPresent(String.self, forKey: .heureDebut)) ?? 0
        let end = PostgresTime.minutes(from: try c.decodeIfPresent(String.self, forKey: .heureFin)) ?? start
        slot = TimeSlot(startMinutes: start, durationMinutes: max(0, end - start))
        courtId = try c.decodeIfPresent(UUID.self, forKey: .courtId)
        entraineurProfileId = try c.decodeIfPresent(UUID.self, forKey: .entraineurProfileId)
        statut = (try? c.decode(SessionStatus.self, forKey: .statut)) ?? .prevue
        motifAnnulation = try c.decodeIfPresent(String.self, forKey: .motifAnnulation)
        noteSeance = try c.decodeIfPresent(String.self, forKey: .noteSeance)
    }

    var startsAt: Date {
        Calendar.current.date(byAdding: .minute, value: slot.startMinutes, to: Calendar.current.startOfDay(for: date)) ?? date
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }
}

// MARK: - Inscription

nonisolated enum EnrollmentStatus: String, Sendable, Codable {
    case inscrit
    case listeAttente = "liste_attente"
    case annule, refuse
}

nonisolated enum PaymentStatus: String, Sendable, Codable {
    case du, encaisse, offert

    var label: String {
        switch self {
        case .du: "À régler"
        case .encaisse: "Réglé"
        case .offert: "Offert"
        }
    }
}

/// Une inscription, telle que la base la laisse lire : la sienne pour un
/// membre, toutes celles de ses cours pour un entraîneur.
nonisolated struct ActivityEnrollment: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let activiteId: UUID
    let profileId: UUID?
    let nomAffiche: String?
    let email: String?
    let telephone: String?
    let statut: EnrollmentStatus
    let rangListeAttente: Int?
    let reglement: PaymentStatus
    let commentaire: String?

    static let columns = "id, activite_id, profile_id, nom_affiche, email, telephone, statut, rang_liste_attente, reglement, commentaire"

    enum CodingKeys: String, CodingKey {
        case id, email, telephone, statut, reglement, commentaire
        case activiteId = "activite_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case rangListeAttente = "rang_liste_attente"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        activiteId = try c.decode(UUID.self, forKey: .activiteId)
        profileId = try c.decodeIfPresent(UUID.self, forKey: .profileId)
        nomAffiche = try c.decodeIfPresent(String.self, forKey: .nomAffiche)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        telephone = try c.decodeIfPresent(String.self, forKey: .telephone)
        statut = (try? c.decode(EnrollmentStatus.self, forKey: .statut)) ?? .inscrit
        rangListeAttente = try c.decodeIfPresent(Int.self, forKey: .rangListeAttente)
        reglement = (try? c.decode(PaymentStatus.self, forKey: .reglement)) ?? .du
        commentaire = try c.decodeIfPresent(String.self, forKey: .commentaire)
    }
}

/// Retour de `inscrire_activite`.
nonisolated struct EnrollmentResult: Decodable, Sendable {
    let inscriptionId: UUID
    let statut: EnrollmentStatus
    let rang: Int?

    enum CodingKeys: String, CodingKey {
        case statut, rang
        case inscriptionId = "inscription_id"
    }
}

/// Une personne au nom de qui le membre peut agir : lui-même, ou un enfant
/// dont il est responsable (`mes_profils_geres`).
nonisolated struct ManagedProfile: Identifiable, Hashable, Sendable, Decodable {
    let profileId: UUID
    let clubMemberId: UUID?
    let prenom: String?
    let nom: String?
    let age: Int?
    let avatarUrl: String?
    let sexe: String?
    let classementTennis: String?
    let classementPadel: Double?
    let peutInscrireActivites: Bool
    let estMoi: Bool

    var id: UUID { profileId }

    var displayName: String {
        let full = [prenom, nom].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Membre" : full
    }

    var initials: String {
        let value = (prenom?.first.map(String.init) ?? "") + (nom?.first.map(String.init) ?? "")
        return value.isEmpty ? "?" : value.uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case prenom, nom, age, sexe
        case profileId = "profile_id"
        case clubMemberId = "club_member_id"
        case avatarUrl = "avatar_url"
        case classementTennis = "classement_tennis"
        case classementPadel = "classement_padel"
        case peutInscrireActivites = "peut_inscrire_activites"
        case estMoi = "est_moi"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        clubMemberId = try c.decodeIfPresent(UUID.self, forKey: .clubMemberId)
        prenom = try c.decodeIfPresent(String.self, forKey: .prenom)
        nom = try c.decodeIfPresent(String.self, forKey: .nom)
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        sexe = try c.decodeIfPresent(String.self, forKey: .sexe)
        classementTennis = try c.decodeIfPresent(String.self, forKey: .classementTennis)
        classementPadel = try c.decodeIfPresent(Double.self, forKey: .classementPadel)
        peutInscrireActivites = try c.decodeIfPresent(Bool.self, forKey: .peutInscrireActivites) ?? false
        estMoi = try c.decodeIfPresent(Bool.self, forKey: .estMoi) ?? false
    }
}
