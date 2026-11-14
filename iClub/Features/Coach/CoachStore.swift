//
//  CoachStore.swift
//  iClub
//
//  Rôle
//    Les cours de l'entraîneur, avec toutes leurs séances et leurs inscrits.
//    Un seul objet, partagé par « Mes cours », la fiche d'un cours, l'appel et
//    l'agenda : une présence pointée se voit partout sans rechargement.
//
//  Place dans l'application
//    Créé en `@State` par ActivitiesView (onglet « Cours ») et passé à
//    CoachSpaceView, CoachCourseView, AttendanceView, CreateCourseView et aux
//    fiches d'élève (StudentViews).
//
//  Données lues (via ActivityService, CoachService, ClubDirectoryService)
//    - table `activites` : cours dont `entraineur_profile_id` est l'entraîneur,
//      sauf ceux au statut `annulee` ou `terminee` (brouillons et cours
//      « proposés » au club compris) ;
//    - table `activite_seances` : toutes les séances de ces cours, passées et à
//      venir, tous statuts ;
//    - table `activite_inscriptions` : inscriptions `inscrit` et
//      `liste_attente` de ces cours, que la RLS laisse lire à l'entraîneur du
//      cours ;
//    - table `creneaux_entraineur` : créneaux actifs alloués par le club, pas
//      encore échus (lecture tolérante) ;
//    - fonction SQL `get_club_roster_info` : prénom, nom, photo et âge des
//      inscrits qui ont un compte et des remplaçants.
//
//  Effets de bord
//    Chaque rechargement reprogramme les rappels locaux « faire l'appel »
//    (AttendanceReminders), d'après les séances telles qu'elles sont en base.
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage du projet) ;
//    les lectures réseau sont attendues avec `await`.
//
//  Points d'attention
//    Les dates de séance sont des jours locaux (colonne `date`, lue dans le
//    fuseau de l'appareil), comparés au début du jour courant.
//

import Foundation
import Observation

/// Magasin de l'espace entraîneur : ses cours, leurs séances, leurs inscrits,
/// ses créneaux alloués et les noms des personnes concernées.
@Observable
final class CoachStore {

    /// État du chargement, affiché par CoachSpaceView.
    enum Phase: Equatable {
        /// idle : rien n'a encore été demandé ; loading : premier chargement en
        /// cours ; ready : données disponibles, éventuellement vides.
        case idle, loading, ready
        /// Échec du premier chargement, avec le message à afficher.
        case failed(String)
    }

    /// État courant du chargement.
    private(set) var phase: Phase = .idle
    /// Cours encadrés par l'entraîneur, triés par nom.
    private(set) var activities: [Activity] = []
    /// Toutes les séances, par cours, triées par date puis heure de début.
    private(set) var sessions: [UUID: [ActivitySession]] = [:]
    /// Inscriptions actives (inscrits et liste d'attente), par cours, dans
    /// l'ordre d'inscription.
    private(set) var enrollments: [UUID: [ActivityEnrollment]] = [:]
    /// Créneaux alloués par le club (`creneaux_entraineur`), proposés en tête
    /// du formulaire de création.
    private(set) var slots: [CoachSlot] = []
    /// Prénom, nom et photo des inscrits qui ont un compte.
    private(set) var people: [UUID: RosterInfoRow] = [:]

    /// Club chargé, mémorisé pour `reload()`.
    private var clubId: UUID?
    /// Entraîneur chargé (son `profiles.id`), mémorisé pour `reload()`.
    private var coachId: UUID?

    // MARK: - Lectures dérivées

    /// Cours chargé portant cet identifiant.
    /// - Parameter id: identifiant du cours (`activites.id`).
    /// - Returns: le cours, ou `nil` s'il n'est plus chargé (annulé, terminé).
    func activity(id: UUID) -> Activity? {
        activities.first { $0.id == id }
    }

    /// Séance chargée portant cet identifiant, tous cours confondus.
    /// - Parameter id: identifiant de la séance (`activite_seances.id`).
    /// - Returns: la séance, ou `nil` si elle n'est pas chargée.
    func session(id: UUID) -> ActivitySession? {
        sessions.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Inscrits d'abord, puis la liste d'attente dans l'ordre des rangs.
    /// - Parameter activityId: identifiant du cours.
    /// - Returns: les inscriptions actives triées.
    func roster(of activityId: UUID) -> [ActivityEnrollment] {
        (enrollments[activityId] ?? []).sorted { a, b in
            // Statuts différents : l'inscrit passe devant l'attente.
            if a.statut != b.statut { return a.statut == .inscrit }
            // Même statut : par rang d'attente, une ligne sans rang en dernier.
            return (a.rangListeAttente ?? .max) < (b.rangListeAttente ?? .max)
        }
    }

    /// Ceux qu'on pointe à l'appel : les inscrits, pas la liste d'attente.
    /// - Parameter activityId: identifiant du cours.
    /// - Returns: les inscriptions au statut `inscrit`.
    func enrolled(in activityId: UUID) -> [ActivityEnrollment] {
        roster(of: activityId).filter { $0.statut == .inscrit }
    }

    /// Prochaine séance prévue d'un cours, aujourd'hui compris.
    /// - Parameter activityId: identifiant du cours.
    /// - Returns: la première séance `prevue` datée d'aujourd'hui ou après, ou
    ///   `nil`.
    func nextSession(of activityId: UUID) -> ActivitySession? {
        let today = Calendar.current.startOfDay(for: .now)
        return sessions[activityId]?.first { $0.statut == .prevue && $0.date >= today }
    }

    /// Séances des sept prochains jours, tous cours confondus, dans l'ordre.
    ///
    /// Fenêtre : d'aujourd'hui (inclus) à aujourd'hui + 7 jours (exclu). Les
    /// séances annulées sont écartées ; les séances faites restent, pour
    /// montrer « Appel fait ».
    var weekSessions: [ActivitySession] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        return sessions.values
            .flatMap { $0 }
            .filter { $0.date >= start && $0.date < end && $0.statut != .annulee }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// « Prénom Nom » : nom saisi à l'inscription, sinon celui du compte.
    /// - Parameter enrollment: l'inscription.
    /// - Returns: `nom_affiche` s'il est renseigné (inscription d'un
    ///   non-membre, par exemple), sinon le nom du compte, sinon « Inscrit ».
    func displayName(of enrollment: ActivityEnrollment) -> String {
        if let name = enrollment.nomAffiche?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let id = enrollment.profileId, let info = people[id] { return info.displayName }
        return "Inscrit"
    }

    /// Décompte des places pour l'entraîneur : « 6 inscrits sur 8 »,
    /// « 8 inscrits sur 8 · attente 2 ».
    /// - Parameter activity: le cours.
    /// - Returns: le libellé de la pastille des places.
    func placesLabel(for activity: Activity) -> String {
        let list = enrollments[activity.id] ?? []
        let enrolled = list.filter { $0.statut == .inscrit }.count
        let waiting = list.filter { $0.statut == .listeAttente }.count
        var label = "\(enrolled) inscrit\(enrolled > 1 ? "s" : "") sur \(activity.placesMax)"
        if waiting > 0 { label += " · attente \(waiting)" }
        return label
    }

    // MARK: - Chargement

    /// Premier chargement, appelé par le `.task(id:)` de CoachSpaceView, ou par
    /// l'appel ouvert depuis un rappel avant que l'onglet ait chargé.
    /// - Parameters:
    ///   - clubId: club de l'entraîneur.
    ///   - coachId: identifiant du profil de l'entraîneur.
    func load(clubId: UUID, coachId: UUID) async {
        self.clubId = clubId
        self.coachId = coachId
        await reload()
    }

    /// Relit cours, séances, inscrits et créneaux, reprogramme les rappels
    /// d'appel, puis charge les noms. Les erreurs passent dans `phase`.
    func reload() async {
        guard let clubId, let coachId else { return }
        // Squelettes seulement au premier chargement.
        if activities.isEmpty { phase = .loading }

        do {
            // 1. Cours de l'entraîneur (hors annulés et terminés).
            let loaded = try await ActivityService.loadCoached(clubId: clubId, coachId: coachId)
            let ids = loaded.map(\.id)

            // 2. En parallèle : toutes les séances, les inscriptions actives,
            //    et les créneaux alloués (cette dernière lecture ne lève pas :
            //    liste vide en cas d'échec).
            async let allSessions = ActivityService.allSessions(activityIds: ids)
            async let readable = ActivityService.activeEnrollments(activityIds: ids)
            async let envelope = CoachService.coachSlots(clubId: clubId, coachId: coachId)
            let (sessionList, enrollmentList, slotList) = try await (allSessions, readable, envelope)

            // 3. Publication d'un seul coup, regroupée par cours.
            activities = loaded
            sessions = Dictionary(grouping: sessionList, by: \.activiteId)
            enrollments = Dictionary(grouping: enrollmentList, by: \.activiteId)
            slots = slotList
            phase = .ready

            // Les rappels d'appel suivent les séances telles qu'elles sont
            // maintenant : une séance annulée ne sonne plus.
            await AttendanceReminders.schedule(sessions: sessionList, activities: loaded, coachId: coachId)

            // 4. Noms et photos des inscrits qui ont un compte et des
            //    remplaçants posés sur une séance (lecture tolérante).
            let profileIds = Set(enrollmentList.compactMap(\.profileId) + sessionList.compactMap(\.entraineurProfileId))
            people = await ClubDirectoryService.rosterInfo(profileIds: Array(profileIds))
        } catch {
            // Une coupure réseau ne vide pas un écran déjà affiché.
            phase = activities.isEmpty ? .failed(ActivityServiceError.from(error).localizedDescription) : .ready
        }
    }
}
