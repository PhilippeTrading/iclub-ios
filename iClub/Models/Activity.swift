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
//  Rôle
//    Lignes décodées des cours et événements (`activites`), de leurs séances
//    (`activite_seances`), des inscriptions (`activite_inscriptions`), du
//    retour de la fonction `inscrire_activite`, et des personnes au nom de qui
//    le membre peut agir (fonction `mes_profils_geres`).
//
//  Place dans l'application
//    `ActivityService` (lecture, inscription), `CoachService` (espace
//    entraîneur), `AuthController` (compte famille). Affichés par l'onglet
//    « Cours » (`ActivitiesView`, `ActivityDetailView`) et l'espace entraîneur.
//
//  Droits et sécurité (RLS, migration `20261018100000_entrainement.sql`)
//    - Activités et séances : lisibles par tous les membres du club ; écrites
//      par l'administration, ou par l'entraîneur de l'activité.
//    - Inscriptions : un membre lit les siennes (`profile_id = auth.uid()`),
//      l'entraîneur et l'administration celles de l'activité. Les inscriptions
//      d'un enfant ne remontent pas au parent par cette lecture.
//    - L'inscription elle-même passe par `inscrire_activite` (contrôles d'âge,
//      de niveau, de fenêtre et de places, sous verrou de l'activité).
//

import Foundation

// MARK: - Heures

/// Colonne `time` → minutes depuis minuit. Isolé de l'acteur principal : les
/// lignes sont décodées en arrière-plan.
nonisolated enum PostgresTime {
    /// - Parameter value: heure PostgreSQL (« 14:00:00 » ou « 14:00 »), ou `nil`.
    /// - Returns: minutes depuis minuit, ou `nil` si illisible. Même calcul que
    ///   `ClubSportSettingsRow.minutes(from:)`, isolé ici hors acteur principal.
    static func minutes(from value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// « 14:00:00 », format d'écriture d'une colonne `time`.
    ///
    /// - Parameter minutes: minutes depuis minuit.
    /// - Returns: « HH:MM:00 ».
    static func string(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }
}

// MARK: - Type

/// Nature d'une activité (`activites.type`, contrainte `check` sur ces sept
/// valeurs depuis la migration `20261022100000_parite_doinsport.sql`).
nonisolated enum ActivityType: String, CaseIterable, Sendable, Codable {
    /// Dans l'ordre : cours collectif, stage, leçon individuelle, leçon en duo,
    /// événement, tournoi, animation.
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

    /// Libellé du type au singulier, pour une fiche ou un badge.
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

    /// Pictogramme SF Symbols du type.
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

/// Statut d'une activité (`activites.statut`).
///
/// Cycle : `brouillon` (en préparation), `proposee` (créée par un entraîneur
/// hors de ses créneaux alloués, en attente de validation du club), `ouverte`
/// (en ligne, inscriptions possibles), `complete` (places pleines, liste
/// d'attente encore ouverte ; la base y passe d'elle-même à la dernière place
/// prise et en revient à une désinscription), `terminee`, `annulee`.
nonisolated enum ActivityStatus: String, Sendable, Codable {
    /// Les six valeurs de la contrainte `check` de la colonne.
    case brouillon, proposee, ouverte, complete, terminee, annulee

    /// Libellé affiché (vocabulaire de l'espace entraîneur).
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

/// Une ligne de `activites` : un cours, un stage, une leçon ou un événement.
nonisolated struct Activity: Identifiable, Hashable, Sendable, Decodable {
    /// `id`.
    let id: UUID
    /// `club_id`.
    let clubId: UUID
    /// `nom` : intitulé affiché.
    let nom: String
    /// `type`, `collectif` si la valeur est inconnue.
    let type: ActivityType
    /// `sport`, `tennis` si la valeur est inconnue.
    let sport: Sport
    /// `description` : texte libre de présentation.
    let description: String?
    /// Colonnes d'origine, texte libre : « Mercredi », « 14h00 ».
    /// `jour` : jour de la semaine habituel.
    let jour: String?
    /// `heure` : heure habituelle, texte libre.
    let heure: String?
    /// `court_id` : terrain habituel.
    let courtId: UUID?
    /// `entraineur_profile_id` : entraîneur titulaire (profil).
    let entraineurProfileId: UUID?
    /// `encadrant_nom` : nom affiché de l'encadrant quand il n'a pas de compte.
    let encadrantNom: String?
    /// `niveau_min` : borne basse du niveau demandé (classement stocké).
    let niveauMin: String?
    /// `niveau_max` : borne haute du niveau demandé.
    let niveauMax: String?
    /// `age_min` : âge minimal, en années.
    let ageMin: Int?
    /// `age_max` : âge maximal, en années.
    let ageMax: Int?
    /// `places_max` : nombre de places (6 par défaut en base) ; 0 si absent.
    let placesMax: Int
    /// `liste_attente_max` : taille de la liste d'attente (5 par défaut en
    /// base) ; 0 si absent.
    let listeAttenteMax: Int
    /// `tarif` (`numeric(8, 2)`, euros) : tarif indicatif, affiché mais jamais
    /// encaissé par la plateforme.
    let tarif: Double?
    /// `tarif_libelle` : tarif en texte libre (« 120 € la saison »), prioritaire
    /// sur `tarif` à l'affichage.
    let tarifLibelle: String?
    /// `date_debut` (`date`) : début de la période du cours.
    let dateDebut: Date?
    /// `date_fin` (`date`) : fin de la période.
    let dateFin: Date?
    /// `inscriptions_ouvertes_du` (`timestamptz`) : ouverture des inscriptions.
    let inscriptionsOuvertesDu: Date?
    /// `inscriptions_ouvertes_au` (`timestamptz`) : clôture des inscriptions.
    let inscriptionsOuvertesAu: Date?
    /// `lieu` : lieu en texte libre, pour un événement hors terrain.
    let lieu: String?
    /// `inscrits_min` : nombre minimal d'inscrits pour que l'activité ait lieu.
    let inscritsMin: Int?
    /// `statut`, `ouverte` si la valeur est inconnue.
    let statut: ActivityStatus

    /// Colonnes demandées à `activites`.
    static let columns = """
        id, club_id, nom, type, sport, description, jour, heure, court_id, \
        entraineur_profile_id, encadrant_nom, niveau_min, niveau_max, age_min, age_max, \
        places_max, liste_attente_max, tarif, tarif_libelle, date_debut, date_fin, \
        inscriptions_ouvertes_du, inscriptions_ouvertes_au, lieu, inscrits_min, statut
        """

    /// Correspondance avec les colonnes SQL.
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

    /// Décodage tolérant : identifiants et nom obligatoires ; dates converties
    /// depuis le texte par `SupabaseDate`.
    ///
    /// Attention : `tarif` est une colonne `numeric` décodée directement en
    /// `Double` ; rendue en chaîne par PostgREST, elle ferait échouer la ligne.
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
    /// `nil` si ni le jour ni l'heure ne sont renseignés.
    var usualSchedule: String? {
        let parts = [jour, heure].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « 8 à 14 ans », « 12 ans et plus »…
    /// `nil` sans limite d'âge.
    var ageLabel: String? {
        switch (ageMin, ageMax) {
        case let (min?, max?): "\(min) à \(max) ans"
        case let (min?, nil): "\(min) ans et plus"
        case let (nil, max?): "Jusqu'à \(max) ans"
        default: nil
        }
    }

    /// « Niveau » suivi des deux bornes reliées par un tiret (par exemple 30/4
    /// et 15/2), ou une seule borne suivie de « minimum » ou « maximum ». Le
    /// niveau padel s'écrit avec une virgule. `nil` sans exigence de niveau.
    var levelLabel: String? {
        /// Remplace le point décimal du padel par une virgule.
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
    /// `nil` sans tarif ; le montant est mis en forme en euros, à la française.
    var priceLabel: String? {
        if let tarifLibelle, !tarifLibelle.trimmingCharacters(in: .whitespaces).isEmpty { return tarifLibelle }
        guard let tarif else { return nil }
        return tarif.formatted(.currency(code: "EUR").locale(AppLocale.french))
    }

    /// Toutes les places sont prises (statut `complete`) ; la liste d'attente
    /// peut encore accueillir des inscrits.
    var isFull: Bool { statut == .complete }
}

// MARK: - Séance

/// Statut d'une séance (`activite_seances.statut`) : `prevue`, `faite`
/// (appel terminé), `annulee` (avec motif, terrain rendu), `reportee`.
nonisolated enum SessionStatus: String, Sendable, Codable {
    /// Les quatre valeurs de la contrainte `check` de la colonne.
    case prevue, faite, annulee, reportee

    /// Libellé affiché.
    var label: String {
        switch self {
        case .prevue: "Prévue"
        case .faite: "Faite"
        case .annulee: "Annulée"
        case .reportee: "Reportée"
        }
    }
}

/// Une ligne de `activite_seances` : une date précise d'un cours ou d'un
/// événement.
nonisolated struct ActivitySession: Identifiable, Hashable, Sendable, Decodable {
    /// `id`.
    let id: UUID
    /// `activite_id` : activité dont c'est une séance.
    let activiteId: UUID
    /// `date` (`date`), à minuit local.
    let date: Date
    /// Créneau reconstruit depuis `heure_debut` et `heure_fin`.
    let slot: TimeSlot
    /// `court_id` : terrain de la séance.
    let courtId: UUID?
    /// Remplaçant ponctuel ; `nil` = l'entraîneur habituel.
    /// (`entraineur_profile_id`.)
    let entraineurProfileId: UUID?
    /// `statut`, `prevue` si la valeur est inconnue.
    let statut: SessionStatus
    /// `motif_annulation` : motif saisi à l'annulation.
    let motifAnnulation: String?
    /// `note_seance` : note de l'entraîneur sur le groupe, jamais sur un élève.
    let noteSeance: String?

    /// Colonnes demandées à `activite_seances`.
    static let columns = "id, activite_id, date, heure_debut, heure_fin, court_id, entraineur_profile_id, statut, motif_annulation, note_seance"

    /// Correspondance avec les colonnes SQL (les deux heures n'ont pas de
    /// propriété propre : elles forment `slot`).
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

    /// Décodage : une date illisible fait refuser la ligne ; une heure
    /// illisible donne minuit (début) ou une durée nulle (fin).
    ///
    /// - Throws: `DecodingError` si l'identifiant, l'activité ou la date
    ///   manquent ou sont illisibles.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        activiteId = try c.decode(UUID.self, forKey: .activiteId)
        guard let day = SupabaseDate.parse(try c.decode(String.self, forKey: .date)) else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "date illisible")
        }
        date = day
        // Heures en minutes depuis minuit ; fin absente = début (durée nulle).
        let start = PostgresTime.minutes(from: try c.decodeIfPresent(String.self, forKey: .heureDebut)) ?? 0
        let end = PostgresTime.minutes(from: try c.decodeIfPresent(String.self, forKey: .heureFin)) ?? start
        slot = TimeSlot(startMinutes: start, durationMinutes: max(0, end - start))
        courtId = try c.decodeIfPresent(UUID.self, forKey: .courtId)
        entraineurProfileId = try c.decodeIfPresent(UUID.self, forKey: .entraineurProfileId)
        statut = (try? c.decode(SessionStatus.self, forKey: .statut)) ?? .prevue
        motifAnnulation = try c.decodeIfPresent(String.self, forKey: .motifAnnulation)
        noteSeance = try c.decodeIfPresent(String.self, forKey: .noteSeance)
    }

    /// Instant de début de la séance (jour à minuit local plus l'heure de début).
    var startsAt: Date {
        Calendar.current.date(byAdding: .minute, value: slot.startMinutes, to: Calendar.current.startOfDay(for: date)) ?? date
    }

    /// La séance a lieu aujourd'hui (calendrier de l'appareil).
    var isToday: Bool { Calendar.current.isDateInToday(date) }
}

// MARK: - Inscription

/// Statut d'une inscription (`activite_inscriptions.statut`).
nonisolated enum EnrollmentStatus: String, Sendable, Codable {
    /// Place obtenue.
    case inscrit
    /// En liste d'attente, avec un rang.
    case listeAttente = "liste_attente"
    /// `annule` : désinscrit ; `refuse` : refusé par le club.
    case annule, refuse
}

/// Suivi du règlement d'une inscription (`activite_inscriptions.reglement`) :
/// la plateforme n'encaisse rien, le secrétariat le note à la main.
nonisolated enum PaymentStatus: String, Sendable, Codable {
    /// `du` : à régler ; `encaisse` : réglé ; `offert` : gratuit.
    case du, encaisse, offert

    /// Libellé affiché.
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
    /// `id` : identifiant de l'inscription (sert à la désinscription et aux
    /// présences).
    let id: UUID
    /// `activite_id`.
    let activiteId: UUID
    /// `profile_id` : l'inscrit ; `nil` pour un non-membre inscrit par le club.
    let profileId: UUID?
    /// `nom_affiche` : nom d'un inscrit sans profil.
    let nomAffiche: String?
    /// `email` : coordonnée d'un inscrit sans profil.
    let email: String?
    /// `telephone` : coordonnée d'un inscrit sans profil.
    let telephone: String?
    /// `statut`, `inscrit` si la valeur est inconnue.
    let statut: EnrollmentStatus
    /// `rang_liste_attente` : position dans la file, `nil` hors liste d'attente.
    let rangListeAttente: Int?
    /// `reglement`, `du` si la valeur est inconnue.
    let reglement: PaymentStatus
    /// `commentaire` : note libre sur l'inscription.
    let commentaire: String?

    /// Colonnes demandées à `activite_inscriptions`.
    static let columns = "id, activite_id, profile_id, nom_affiche, email, telephone, statut, rang_liste_attente, reglement, commentaire"

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, email, telephone, statut, reglement, commentaire
        case activiteId = "activite_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case rangListeAttente = "rang_liste_attente"
    }

    /// Décodage tolérant : identifiants obligatoires, statuts inconnus
    /// ramenés à leur valeur la plus courante.
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
/// (La fonction rend une table d'une ligne : `inscription_id, statut, rang`.)
nonisolated struct EnrollmentResult: Decodable, Sendable {
    /// `inscription_id` : inscription créée.
    let inscriptionId: UUID
    /// `statut` : `inscrit` si une place restait, sinon `liste_attente`.
    let statut: EnrollmentStatus
    /// `rang` : position en liste d'attente, `nil` pour une place obtenue.
    let rang: Int?

    /// Correspondance avec les colonnes rendues par la fonction.
    enum CodingKeys: String, CodingKey {
        case statut, rang
        case inscriptionId = "inscription_id"
    }
}

/// Une personne au nom de qui le membre peut agir : lui-même, ou un enfant
/// dont il est responsable (`mes_profils_geres`).
///
/// La fonction rend aussi `compte_gere` et `peut_reserver`, non décodés ici.
/// Le membre lui-même vient en premier (`est_moi`), puis ses enfants par
/// prénom ; un enfant au profil supprimé n'y figure pas.
nonisolated struct ManagedProfile: Identifiable, Hashable, Sendable, Decodable {
    /// `profile_id`.
    let profileId: UUID
    /// `club_member_id` : appartenance de cette personne au club.
    let clubMemberId: UUID?
    /// `prenom`.
    let prenom: String?
    /// `nom`.
    let nom: String?
    /// `age` : années révolues, calculées par la base depuis la date de
    /// naissance (qui n'est pas exposée).
    let age: Int?
    /// `avatar_url`.
    let avatarUrl: String?
    /// `sexe` : « H » ou « F ».
    let sexe: String?
    /// `classement_tennis` dans le club.
    let classementTennis: String?
    /// `classement_padel` dans le club.
    let classementPadel: Double?
    /// `peut_inscrire_activites` : droit du parent d'inscrire cet enfant à un
    /// cours (lien de famille) ; toujours vrai pour soi. Faux à défaut.
    let peutInscrireActivites: Bool
    /// `est_moi` : la ligne du membre connecté lui-même. Faux à défaut.
    let estMoi: Bool

    /// Identifiant de liste : le profil.
    var id: UUID { profileId }

    /// Prénom et nom, « Membre » s'ils sont vides.
    var displayName: String {
        let full = [prenom, nom].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Membre" : full
    }

    /// Initiales du prénom et du nom, « ? » à défaut.
    var initials: String {
        let value = (prenom?.first.map(String.init) ?? "") + (nom?.first.map(String.init) ?? "")
        return value.isEmpty ? "?" : value.uppercased()
    }

    /// Correspondance avec les colonnes rendues par la fonction.
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

    /// Décodage tolérant : seul le profil est obligatoire.
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
