//
//  ActivitiesStore.swift
//  iClub
//
//  Les activités en ligne du club, leurs prochaines séances, et les
//  inscriptions du membre.
//
//  Le nombre d'inscrits d'une activité n'est lisible que par son entraîneur et
//  par l'administration : un membre ne voit que ses propres inscriptions. Pour
//  lui, les places s'affichent donc en capacité (« 8 places ») et en état
//  (« Complet »), pas en décompte.
//

import Foundation
import Observation

@Observable
final class ActivitiesStore {

    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var activities: [Activity] = []
    /// Séances à venir, par activité, dans l'ordre chronologique.
    private(set) var upcoming: [UUID: [ActivitySession]] = [:]
    /// Inscriptions actives lisibles, par activité.
    private(set) var enrollments: [UUID: [ActivityEnrollment]] = [:]
    /// Prénom et nom des entraîneurs (et remplaçants), par profil.
    private(set) var people: [UUID: RosterInfoRow] = [:]

    private var clubId: UUID?
    private(set) var profileId: UUID?

    // MARK: - Lectures dérivées

    func activity(id: UUID) -> Activity? {
        activities.first { $0.id == id }
    }

    /// Sports qui ont au moins une activité, pour n'afficher que des filtres
    /// utiles.
    var sports: [Sport] {
        let present = Set(activities.map(\.sport))
        return Sport.allCases.filter(present.contains)
    }

    /// Mon inscription (pas celle d'un enfant) à une activité.
    func myEnrollment(in activityId: UUID) -> ActivityEnrollment? {
        enrollments[activityId]?.first { $0.profileId == profileId }
    }

    func isEnrolled(_ activityId: UUID) -> Bool {
        myEnrollment(in: activityId) != nil
    }

    func nextSession(of activityId: UUID) -> ActivitySession? {
        upcoming[activityId]?.first
    }

    /// « Thomas Garnier », ou l'encadrant libre saisi par le club.
    func coachName(for activity: Activity) -> String? {
        if let id = activity.entraineurProfileId, let info = people[id] {
            return info.displayName
        }
        let free = activity.encadrantNom?.trimmingCharacters(in: .whitespaces)
        return (free?.isEmpty ?? true) ? nil : free
    }

    func name(of profileId: UUID) -> String? {
        people[profileId]?.displayName
    }

    /// « 6 inscrits sur 8 », « Complet · liste d'attente 2 », « 8 places ».
    ///
    /// Le décompte n'existe que si la base laisse lire les inscriptions de
    /// l'activité, c'est-à-dire pour son entraîneur.
    func placesLabel(for activity: Activity) -> String {
        let isMine = activity.entraineurProfileId != nil && activity.entraineurProfileId == profileId
        if isMine {
            let list = enrollments[activity.id] ?? []
            let enrolled = list.filter { $0.statut == .inscrit }.count
            let waiting = list.filter { $0.statut == .listeAttente }.count
            var label = enrolled >= activity.placesMax
                ? "Complet"
                : "\(enrolled) inscrit\(enrolled > 1 ? "s" : "") sur \(activity.placesMax)"
            if waiting > 0 { label += " · liste d'attente \(waiting)" }
            return label
        }

        if activity.isFull {
            return activity.listeAttenteMax > 0 ? "Complet · liste d'attente" : "Complet"
        }
        return activity.placesMax == 1 ? "1 place" : "\(activity.placesMax) places"
    }

    // MARK: - Chargement

    func load(clubId: UUID, profileId: UUID) async {
        self.clubId = clubId
        self.profileId = profileId
        await reload()
    }

    func reload() async {
        guard let clubId else { return }
        if activities.isEmpty { phase = .loading }

        do {
            let loaded = try await ActivityService.loadPublished(clubId: clubId)
            let ids = loaded.map(\.id)

            async let sessionsTask = ActivityService.upcomingSessions(activityIds: ids)
            async let enrollmentsTask = ActivityService.activeEnrollments(activityIds: ids)
            let (sessions, readable) = try await (sessionsTask, enrollmentsTask)

            activities = loaded
            upcoming = Dictionary(grouping: sessions, by: \.activiteId)
            enrollments = Dictionary(grouping: readable, by: \.activiteId)
            phase = .ready

            let coachIds = Set(loaded.compactMap(\.entraineurProfileId) + sessions.compactMap(\.entraineurProfileId))
            people = await ClubDirectoryService.rosterInfo(profileIds: Array(coachIds))
        } catch {
            // Une coupure réseau ne doit pas vider un écran déjà affiché.
            phase = activities.isEmpty ? .failed(ActivityServiceError.from(error).localizedDescription) : .ready
        }
    }
}
