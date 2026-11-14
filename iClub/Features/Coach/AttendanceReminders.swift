//
//  AttendanceReminders.swift
//  iClub
//
//  Rôle
//    « Le cours … vient de commencer. Touchez ici pour faire l'appel. »
//
//    Programmé sur l'iPhone de l'entraîneur, à l'heure exacte de chacune de ses
//    séances à venir : aucune tâche serveur n'est nécessaire, et le rappel arrive
//    même sans réseau. La liste est reconstruite à chaque ouverture de l'app et à
//    chaque rechargement de ses cours, si bien qu'une séance annulée ou déplacée
//    ne sonne jamais.
//
//    Ce n'est pas une suggestion de partie : la règle « aucune notification
//    locale » ne vaut que pour celles-là, dont le serveur compte les envois.
//
//  Place dans l'application
//    - `refresh(for:)` : appelé par MainTabView à l'ouverture de la session ;
//    - `schedule(...)` : appelé par CoachStore après chaque rechargement ;
//    - `clear()` : appelé par AuthService à la déconnexion et à la suppression
//      du compte.
//    Le tap sur le rappel est reçu par PushService.handleTap, qui reconnaît le
//    type « appel » dans `userInfo` et publie `PushService.attendanceRequested` ;
//    MainTabView ouvre alors l'appel de la séance dans l'onglet « Cours ».
//
//  Données
//    Tables `activites` et `activite_seances`, lues par ActivityService.
//
//  Points d'attention
//    - iOS garde au plus 64 notifications locales en attente par app : on en
//      programme 40 au plus, sur 14 jours, pour laisser de la place au reste
//      (les rappels de réservation, BookingReminders, en prennent jusqu'à 20).
//    - Sans autorisation des notifications (ni accordée, ni provisoire), rien
//      n'est programmé, mais les anciens rappels sont tout de même retirés.
//    - Le texte dit toujours « Le cours », y compris pour un stage ou une
//      leçon.
//

import Foundation
import UserNotifications

/// Rappels locaux « faire l'appel » de l'entraîneur. Fonctions statiques sans
/// état ; les rappels vivent dans le centre de notifications d'iOS, repérés par
/// le préfixe de leur identifiant.
enum AttendanceReminders {

    /// Valeur de la clé « type » du `userInfo` : c'est à elle que PushService
    /// reconnaît un rappel d'appel.
    static let kind = "appel"
    /// Préfixe des identifiants de requête (« appel- » suivi de l'identifiant
    /// de la séance), pour retrouver et retirer ces rappels sans toucher aux
    /// autres notifications de l'app.
    private static let prefix = "appel-"
    /// iOS garde au plus 64 notifications programmées par app : on en laisse
    /// pour le reste.
    private static let maxScheduled = 40
    /// Horizon de programmation, en jours à partir de maintenant.
    private static let horizonDays = 14

    /// Recharge les cours de l'entraîneur et reprogramme ses rappels.
    ///
    /// Ne fait rien pour un profil qui n'est pas entraîneur, ni si une lecture
    /// échoue (les rappels déjà programmés restent alors en place).
    /// - Parameter profile: profil de la session.
    static func refresh(for profile: SessionProfile) async {
        guard profile.isCoach,
              let activities = try? await ActivityService.loadCoached(clubId: profile.clubId, coachId: profile.id),
              let sessions = try? await ActivityService.upcomingSessions(activityIds: activities.map(\.id))
        else { return }
        await schedule(sessions: sessions, activities: activities, coachId: profile.id)
    }

    /// Remplace tous les rappels d'appel par ceux des séances à venir que
    /// l'entraîneur encadre lui-même (pas celles où un remplaçant est posé).
    /// - Parameters:
    ///   - sessions: séances connues (passées comprises : le filtre écarte
    ///     tout ce qui n'est pas à venir et prévu).
    ///   - activities: cours correspondants, pour le nom affiché.
    ///   - coachId: identifiant de l'entraîneur.
    static func schedule(sessions: [ActivitySession], activities: [Activity], coachId: UUID) async {
        let center = UNUserNotificationCenter.current()

        // 1. Retire tous les rappels d'appel en attente, et eux seuls.
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        // 2. Sans autorisation d'afficher, inutile d'en programmer.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        // 3. Séances retenues : prévues, commençant entre maintenant et
        //    l'horizon, encadrées par l'entraîneur habituel (pas de remplaçant,
        //    ou c'est lui), les plus proches d'abord, dans la limite du plafond.
        let names = Dictionary(activities.map { ($0.id, $0.nom) }, uniquingKeysWith: { a, _ in a })
        let now = Date.now
        let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) ?? now

        let upcoming = sessions
            .filter { $0.statut == .prevue && $0.startsAt > now && $0.startsAt < horizon }
            .filter { $0.entraineurProfileId == nil || $0.entraineurProfileId == coachId }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(maxScheduled)

        // 4. Une notification par séance, déclenchée à la minute de son début
        //    (heure locale de l'appareil), une seule fois.
        for session in upcoming {
            let content = UNMutableNotificationContent()
            content.title = "Faire l'appel"
            content.body = "Le cours \(names[session.activiteId] ?? "") vient de commencer. Touchez ici pour faire l'appel."
            content.sound = .default
            // Lu par PushService.handleTap pour ouvrir l'appel de cette séance.
            content.userInfo = ["type": kind, "seance_id": session.id.uuidString]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: session.startsAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: prefix + session.id.uuidString, content: content, trigger: trigger)
            // Un échec de programmation est ignoré : le rappel manquera, sans
            // autre conséquence.
            try? await center.add(request)
        }
    }

    /// À la déconnexion : un autre membre ne doit pas recevoir les rappels.
    ///
    /// Retire tous les rappels d'appel en attente sur l'appareil.
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
