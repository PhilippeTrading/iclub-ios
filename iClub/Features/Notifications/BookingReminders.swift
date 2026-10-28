//
//  BookingReminders.swift
//  iClub
//
//  Rappel une heure avant chaque réservation à venir :
//  « Padel 2 à 18 h 30 · dans une heure ».
//
//  Programmé sur l'iPhone du membre, comme le rappel d'appel de l'entraîneur :
//  aucune tâche serveur, et la liste est refaite à chaque ouverture de l'app et
//  après chaque réservation ou annulation. Une réservation annulée ne sonne pas.
//
//  Le membre peut couper ces rappels dans son profil.
//

import Foundation
import UserNotifications

enum BookingReminders {

    static let kind = "rappel_reservation"
    private static let prefix = "resa-"
    private static let leadTime: TimeInterval = 60 * 60
    /// iOS garde au plus 64 notifications programmées par app ; on en laisse
    /// pour les rappels d'appel des entraîneurs.
    private static let maxScheduled = 20
    private static let enabledKey = "reminders.bookings.enabled"

    /// Activés par défaut : c'est le rappel qu'on attend d'une app de réservation.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Recharge les réservations du membre et reprogramme ses rappels.
    static func refresh(for profile: SessionProfile) async {
        guard let reservations = try? await ReservationService.loadMine(clubId: profile.clubId, profileId: profile.id) else { return }
        await schedule(reservations)
    }

    static func schedule(_ reservations: [MyReservation]) async {
        await clear()
        guard isEnabled else { return }

        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let now = Date.now
        let upcoming = reservations
            .filter { !$0.isCancelled && $0.startsAt.addingTimeInterval(-leadTime) > now }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(maxScheduled)

        for reservation in upcoming {
            let content = UNMutableNotificationContent()
            content.title = "\(reservation.sport?.displayName ?? "Réservation") à \(reservation.slot.startLabel)"
            content.body = "\(reservation.courtName) · dans une heure. Bon match !"
            content.sound = .default
            content.userInfo = ["type": kind, "reservation_id": reservation.id.uuidString]

            let fireDate = reservation.startsAt.addingTimeInterval(-leadTime)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: prefix + reservation.id.uuidString, content: content, trigger: trigger)
            )
        }
    }

    /// Une réservation vient d'être annulée ou quittée : son rappel ne doit
    /// pas sonner.
    static func cancel(reservationId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prefix + reservationId.uuidString])
    }

    /// À la déconnexion, ou quand le membre coupe les rappels.
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
