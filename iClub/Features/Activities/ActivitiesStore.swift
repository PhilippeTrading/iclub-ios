//
//  ActivitiesStore.swift
//  iClub
//
//  Rôle
//    Les activités en ligne du club, leurs prochaines séances, et les
//    inscriptions du membre. Source des données de l'onglet « Cours »
//    (ActivitiesView, ActivityCard) et du détail d'une activité
//    (ActivityDetailView), qui le partagent : une inscription faite dans le
//    détail recharge le magasin et la liste se met à jour.
//
//  Données lues (via ActivityService et ClubDirectoryService)
//    - table `activites` : activités du club au statut `ouverte` ou `complete`,
//      triées par nom ;
//    - table `activite_seances` : séances au statut `prevue`, à partir
//      d'aujourd'hui (date locale de l'appareil), triées par date puis heure ;
//    - table `activite_inscriptions` : inscriptions `inscrit` ou
//      `liste_attente` lisibles par l'utilisateur connecté ;
//    - fonction SQL `get_club_roster_info` : prénom, nom et photo des
//      entraîneurs et remplaçants (lecture des fiches des autres membres
//      interdite autrement).
//
//  Droits et sécurité
//    Le nombre d'inscrits d'une activité n'est lisible que par son entraîneur et
//    par l'administration : un membre ne voit que ses propres inscriptions
//    (politique RLS « inscriptions_lecture » de la table, migration
//    20261018100000_entrainement). Pour lui, les places s'affichent donc en
//    capacité (« 8 places ») et en état (« Complet »), pas en décompte.
//
//  Fil d'exécution
//    Classe `@Observable`, isolée sur l'acteur principal comme tout le code de
//    l'app (réglage SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor) : les vues la
//    lisent directement, les appels réseau sont attendus avec `await`.
//
//  Points d'attention
//    - Limite connue : quand un parent agit pour un enfant (sélecteur du haut de
//      l'écran), `profileId` est celui de l'enfant, mais la règle RLS ci-dessus
//      ne laisse lire que les inscriptions dont `profile_id` est l'utilisateur
//      connecté. Les inscriptions de l'enfant ne remontent donc pas (sauf si le
//      parent est administrateur ou entraîneur de l'activité) : l'écran ne le
//      montre pas inscrit, et une nouvelle inscription est refusée par la base
//      (« Déjà inscrit à cette activité »).
//    - Aucun cache disque : tout est relu à chaque chargement.
//

import Foundation
import Observation

/// Magasin des activités publiées du club, de leurs séances à venir et des
/// inscriptions lisibles, pour l'onglet « Cours » côté membre.
@Observable
final class ActivitiesStore {

    /// État du chargement, affiché par ActivitiesView.
    enum Phase: Equatable {
        /// idle : rien n'a encore été demandé ; loading : premier chargement en
        /// cours (squelettes à l'écran) ; ready : données disponibles,
        /// éventuellement vides.
        case idle, loading, ready
        /// Échec du premier chargement, avec le message à afficher.
        case failed(String)
    }

    /// État courant du chargement.
    private(set) var phase: Phase = .idle
    /// Activités publiées (statut `ouverte` ou `complete`), triées par nom.
    private(set) var activities: [Activity] = []
    /// Séances à venir, par activité, dans l'ordre chronologique.
    private(set) var upcoming: [UUID: [ActivitySession]] = [:]
    /// Inscriptions actives lisibles, par activité.
    private(set) var enrollments: [UUID: [ActivityEnrollment]] = [:]
    /// Prénom et nom des entraîneurs (et remplaçants), par profil.
    private(set) var people: [UUID: RosterInfoRow] = [:]

    /// Club chargé, mémorisé pour `reload()`.
    private var clubId: UUID?
    /// Profil au nom duquel on consulte (le membre, ou l'enfant choisi en haut
    /// de l'écran), qui décide de « mon » inscription et de « mes » cours.
    private(set) var profileId: UUID?

    // MARK: - Lectures dérivées

    /// Activité chargée portant cet identifiant.
    /// - Parameter id: identifiant de l'activité (`activites.id`).
    /// - Returns: l'activité, ou `nil` si elle n'est plus publiée (retirée,
    ///   annulée ou terminée depuis le dernier chargement).
    func activity(id: UUID) -> Activity? {
        activities.first { $0.id == id }
    }

    /// Sports qui ont au moins une activité, pour n'afficher que des filtres
    /// utiles. Dans l'ordre de `Sport.allCases` (tennis, padel, pickleball).
    var sports: [Sport] {
        let present = Set(activities.map(\.sport))
        return Sport.allCases.filter(present.contains)
    }

    /// Mon inscription (pas celle d'un enfant) à une activité.
    ///
    /// « Mon » désigne `profileId`, donc l'enfant quand le parent agit pour lui
    /// (voir la limite connue en tête de fichier).
    /// - Parameter activityId: identifiant de l'activité.
    /// - Returns: l'inscription `inscrit` ou `liste_attente` de ce profil, ou
    ///   `nil` s'il n'en a pas (ou si elle n'est pas lisible).
    func myEnrollment(in activityId: UUID) -> ActivityEnrollment? {
        enrollments[activityId]?.first { $0.profileId == profileId }
    }

    /// Vrai si le profil courant est inscrit ou en liste d'attente.
    /// - Parameter activityId: identifiant de l'activité.
    /// - Returns: `true` quand `myEnrollment(in:)` trouve une inscription.
    func isEnrolled(_ activityId: UUID) -> Bool {
        myEnrollment(in: activityId) != nil
    }

    /// Prochaine séance prévue d'une activité.
    /// - Parameter activityId: identifiant de l'activité.
    /// - Returns: la première séance à venir, ou `nil` s'il n'y en a aucune.
    func nextSession(of activityId: UUID) -> ActivitySession? {
        upcoming[activityId]?.first
    }

    /// « Prénom Nom » de l'entraîneur qui a un compte, ou l'encadrant libre
    /// saisi par le club (`encadrant_nom`).
    /// - Parameter activity: l'activité.
    /// - Returns: le nom à afficher, ou `nil` si l'activité n'a ni entraîneur
    ///   connu ni encadrant saisi.
    func coachName(for activity: Activity) -> String? {
        // Entraîneur rattaché à un compte et retrouvé par get_club_roster_info.
        if let id = activity.entraineurProfileId, let info = people[id] {
            return info.displayName
        }
        // Sinon le nom libre, s'il n'est pas vide une fois les blancs retirés.
        let free = activity.encadrantNom?.trimmingCharacters(in: .whitespaces)
        return (free?.isEmpty ?? true) ? nil : free
    }

    /// Nom affiché d'un entraîneur ou d'un remplaçant chargé.
    /// - Parameter profileId: identifiant du profil.
    /// - Returns: « Prénom Nom », ou `nil` si ce profil n'a pas été chargé.
    func name(of profileId: UUID) -> String? {
        people[profileId]?.displayName
    }

    /// « 6 inscrits sur 8 », « Complet · liste d'attente 2 », « 8 places ».
    ///
    /// Le décompte n'existe que si la base laisse lire les inscriptions de
    /// l'activité, c'est-à-dire pour son entraîneur.
    /// - Parameter activity: l'activité.
    /// - Returns: le libellé de la pastille des places.
    func placesLabel(for activity: Activity) -> String {
        // Activité encadrée par le profil courant : décompte réel.
        let isMine = activity.entraineurProfileId != nil && activity.entraineurProfileId == profileId
        if isMine {
            let list = enrollments[activity.id] ?? []
            let enrolled = list.filter { $0.statut == .inscrit }.count
            let waiting = list.filter { $0.statut == .listeAttente }.count
            // Plein dès que les inscrits atteignent la capacité, même si le
            // statut de l'activité n'est pas encore passé à « complete ».
            var label = enrolled >= activity.placesMax
                ? "Complet"
                : "\(enrolled) inscrit\(enrolled > 1 ? "s" : "") sur \(activity.placesMax)"
            if waiting > 0 { label += " · liste d'attente \(waiting)" }
            return label
        }

        // Membre : état d'après le statut de l'activité, sinon la capacité.
        // « Complet · liste d'attente » seulement si le club en a prévu une.
        if activity.isFull {
            return activity.listeAttenteMax > 0 ? "Complet · liste d'attente" : "Complet"
        }
        return activity.placesMax == 1 ? "1 place" : "\(activity.placesMax) places"
    }

    // MARK: - Chargement

    /// Premier chargement, ou changement de profil (passage au compte d'un
    /// enfant). Appelé par le `.task(id:)` d'ActivitiesView.
    /// - Parameters:
    ///   - clubId: club de l'utilisateur.
    ///   - profileId: profil au nom duquel on consulte.
    func load(clubId: UUID, profileId: UUID) async {
        self.clubId = clubId
        self.profileId = profileId
        await reload()
    }

    /// Relit activités, séances, inscriptions et noms des entraîneurs.
    ///
    /// Appelée par `load`, par le geste « tirer pour rafraîchir » et après une
    /// inscription ou une désinscription. Les erreurs ne sont pas levées : elles
    /// passent dans `phase`.
    func reload() async {
        guard let clubId else { return }
        // Squelettes seulement au premier chargement : un rafraîchissement garde
        // la liste affichée.
        if activities.isEmpty { phase = .loading }

        do {
            // 1. Activités publiées du club (statut ouverte ou complete).
            let loaded = try await ActivityService.loadPublished(clubId: clubId)
            let ids = loaded.map(\.id)

            // 2. En parallèle : séances prévues à partir d'aujourd'hui, et
            //    inscriptions actives lisibles (la RLS filtre côté base).
            async let sessionsTask = ActivityService.upcomingSessions(activityIds: ids)
            async let enrollmentsTask = ActivityService.activeEnrollments(activityIds: ids)
            let (sessions, readable) = try await (sessionsTask, enrollmentsTask)

            // 3. Publication d'un seul coup, regroupée par activité.
            activities = loaded
            upcoming = Dictionary(grouping: sessions, by: \.activiteId)
            enrollments = Dictionary(grouping: readable, by: \.activiteId)
            phase = .ready

            // 4. Noms des entraîneurs habituels et des remplaçants des séances,
            //    après l'affichage : ils arrivent un instant plus tard. Lecture
            //    tolérante (dictionnaire vide en cas d'échec).
            let coachIds = Set(loaded.compactMap(\.entraineurProfileId) + sessions.compactMap(\.entraineurProfileId))
            people = await ClubDirectoryService.rosterInfo(profileIds: Array(coachIds))
        } catch {
            // Une coupure réseau ne doit pas vider un écran déjà affiché.
            phase = activities.isEmpty ? .failed(ActivityServiceError.from(error).localizedDescription) : .ready
        }
    }
}
