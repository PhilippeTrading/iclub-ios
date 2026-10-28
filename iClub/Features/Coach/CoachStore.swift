//
//  CoachStore.swift
//  iClub
//
//  Les cours de l'entraîneur, avec toutes leurs séances et leurs inscrits.
//  Un seul objet, partagé par « Mes cours », la fiche d'un cours, l'appel et
//  l'agenda : une présence pointée se voit partout sans rechargement.
//

import Foundation
import Observation

@Observable
final class CoachStore {

    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var activities: [Activity] = []
    private(set) var sessions: [UUID: [ActivitySession]] = [:]
    private(set) var enrollments: [UUID: [ActivityEnrollment]] = [:]
    private(set) var slots: [CoachSlot] = []
    /// Prénom, nom et photo des inscrits qui ont un compte.
    private(set) var people: [UUID: RosterInfoRow] = [:]

    private var clubId: UUID?
    private var coachId: UUID?

    // MARK: - Lectures dérivées

    func activity(id: UUID) -> Activity? {
        activities.first { $0.id == id }
    }

    func session(id: UUID) -> ActivitySession? {
        sessions.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Inscrits d'abord, puis la liste d'attente dans l'ordre des rangs.
    func roster(of activityId: UUID) -> [ActivityEnrollment] {
        (enrollments[activityId] ?? []).sorted { a, b in
            if a.statut != b.statut { return a.statut == .inscrit }
            return (a.rangListeAttente ?? .max) < (b.rangListeAttente ?? .max)
        }
    }

    /// Ceux qu'on pointe à l'appel : les inscrits, pas la liste d'attente.
    func enrolled(in activityId: UUID) -> [ActivityEnrollment] {
        roster(of: activityId).filter { $0.statut == .inscrit }
    }

    func nextSession(of activityId: UUID) -> ActivitySession? {
        let today = Calendar.current.startOfDay(for: .now)
        return sessions[activityId]?.first { $0.statut == .prevue && $0.date >= today }
    }

    /// Séances des sept prochains jours, tous cours confondus, dans l'ordre.
    var weekSessions: [ActivitySession] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        return sessions.values
            .flatMap { $0 }
            .filter { $0.date >= start && $0.date < end && $0.statut != .annulee }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// « Sarah Dufour » : nom saisi à l'inscription, sinon celui du compte.
    func displayName(of enrollment: ActivityEnrollment) -> String {
        if let name = enrollment.nomAffiche?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let id = enrollment.profileId, let info = people[id] { return info.displayName }
        return "Inscrit"
    }

    func placesLabel(for activity: Activity) -> String {
        let list = enrollments[activity.id] ?? []
        let enrolled = list.filter { $0.statut == .inscrit }.count
        let waiting = list.filter { $0.statut == .listeAttente }.count
        var label = "\(enrolled) inscrit\(enrolled > 1 ? "s" : "") sur \(activity.placesMax)"
        if waiting > 0 { label += " · attente \(waiting)" }
        return label
    }

    // MARK: - Chargement

    func load(clubId: UUID, coachId: UUID) async {
        self.clubId = clubId
        self.coachId = coachId
        await reload()
    }

    func reload() async {
        guard let clubId, let coachId else { return }
        if activities.isEmpty { phase = .loading }

        do {
            let loaded = try await ActivityService.loadCoached(clubId: clubId, coachId: coachId)
            let ids = loaded.map(\.id)

            async let allSessions = ActivityService.allSessions(activityIds: ids)
            async let readable = ActivityService.activeEnrollments(activityIds: ids)
            async let envelope = CoachService.coachSlots(clubId: clubId, coachId: coachId)
            let (sessionList, enrollmentList, slotList) = try await (allSessions, readable, envelope)

            activities = loaded
            sessions = Dictionary(grouping: sessionList, by: \.activiteId)
            enrollments = Dictionary(grouping: enrollmentList, by: \.activiteId)
            slots = slotList
            phase = .ready

            // Les rappels d'appel suivent les séances telles qu'elles sont
            // maintenant : une séance annulée ne sonne plus.
            await AttendanceReminders.schedule(sessions: sessionList, activities: loaded, coachId: coachId)

            let profileIds = Set(enrollmentList.compactMap(\.profileId) + sessionList.compactMap(\.entraineurProfileId))
            people = await ClubDirectoryService.rosterInfo(profileIds: Array(profileIds))
        } catch {
            phase = activities.isEmpty ? .failed(ActivityServiceError.from(error).localizedDescription) : .ready
        }
    }
}
