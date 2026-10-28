//
//  AttendanceReminders.swift
//  iClub
//
//  « Le cours … vient de commencer. Touchez ici pour faire l'appel. »
//
//  Programmé sur l'iPhone de l'entraîneur, à l'heure exacte de chacune de ses
//  séances à venir : aucune tâche serveur n'est nécessaire, et le rappel arrive
//  même sans réseau. La liste est reconstruite à chaque ouverture de l'app et à
//  chaque rechargement de ses cours, si bien qu'une séance annulée ou déplacée
//  ne sonne jamais.
//
//  Ce n'est pas une suggestion de partie : la règle « aucune notification
//  locale » ne vaut que pour celles-là, dont le serveur compte les envois.
//

import Foundation
import UserNotifications

enum AttendanceReminders {

    static let kind = "appel"
    private static let prefix = "appel-"
    /// iOS garde au plus 64 notifications programmées par app : on en laisse
    /// pour le reste.
    private static let maxScheduled = 40
    private static let horizonDays = 14

    /// Recharge les cours de l'entraîneur et reprogramme ses rappels.
    static func refresh(for profile: SessionProfile) async {
        guard profile.isCoach,
              let activities = try? await ActivityService.loadCoached(clubId: profile.clubId, coachId: profile.id),
              let sessions = try? await ActivityService.upcomingSessions(activityIds: activities.map(\.id))
        else { return }
        await schedule(sessions: sessions, activities: activities, coachId: profile.id)
    }

    /// Remplace tous les rappels d'appel par ceux des séances à venir que
    /// l'entraîneur encadre lui-même (pas celles où un remplaçant est posé).
    static func schedule(sessions: [ActivitySession], activities: [Activity], coachId: UUID) async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let names = Dictionary(activities.map { ($0.id, $0.nom) }, uniquingKeysWith: { a, _ in a })
        let now = Date.now
        let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) ?? now

        let upcoming = sessions
            .filter { $0.statut == .prevue && $0.startsAt > now && $0.startsAt < horizon }
            .filter { $0.entraineurProfileId == nil || $0.entraineurProfileId == coachId }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(maxScheduled)

        for session in upcoming {
            let content = UNMutableNotificationContent()
            content.title = "Faire l'appel"
            content.body = "Le cours \(names[session.activiteId] ?? "") vient de commencer. Touchez ici pour faire l'appel."
            content.sound = .default
            content.userInfo = ["type": kind, "seance_id": session.id.uuidString]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: session.startsAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: prefix + session.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// À la déconnexion : un autre membre ne doit pas recevoir les rappels.
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
