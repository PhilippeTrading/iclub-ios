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
//  Place dans l'application
//    - Reprogrammés par `MainTabView` à l'ouverture de session et à chaque
//      retour de l'app au premier plan, après une réservation
//      (`BookingSummaryView`), après avoir rejoint une partie
//      (`OpenGamesView`), et quand le membre réactive les rappels
//      (`GameNotificationsSection`, profil).
//    - Retirés un à un par `ReservationService.cancel` et
//      `OpenGameService.leave`, en bloc à la déconnexion et à la suppression
//      du compte (`AuthService`), ou quand le membre coupe les rappels.
//    - Le tap sur un rappel ouvre l'historique des réservations
//      (`PushService.handleTap`, puis `MainTabView`).
//
//  Données
//    `ReservationService.loadMine` : réservations du compte connecté, créées
//    par lui ou auxquelles il participe (tables `reservations` et
//    `reservation_participants`). Les réservations prises par un parent pour
//    son enfant en font partie, puisqu'il en est le créateur.
//
//  Ce ne sont pas des notifications push : elles ne passent pas par le
//  serveur et ne sont pas comptées par le ciblage des parties ouvertes. Elles
//  ne sont posées que si le membre a autorisé les notifications.
//

import Foundation
import UserNotifications

/// Rappels locaux une heure avant les réservations à venir du membre.
enum BookingReminders {

    /// Valeur de la clé `type` du rappel, reconnue au tap par `PushService`.
    static let kind = "rappel_reservation"
    /// Préfixe des identifiants de ces notifications, suivi de l'identifiant
    /// de la réservation : permet de les retrouver sans toucher aux autres.
    private static let prefix = "resa-"
    /// Avance du rappel sur le début de la réservation : une heure.
    private static let leadTime: TimeInterval = 60 * 60
    /// iOS garde au plus 64 notifications programmées par app ; on en laisse
    /// pour les rappels d'appel des entraîneurs.
    /// (Ceux-ci en prennent au plus 40 : 20 + 40 reste sous la limite.)
    private static let maxScheduled = 20
    /// Clé du réglage dans `UserDefaults` (propre à l'appareil, pas au compte).
    private static let enabledKey = "reminders.bookings.enabled"

    /// Activés par défaut : c'est le rappel qu'on attend d'une app de réservation.
    /// Modifié par l'interrupteur du profil.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Recharge les réservations du membre et reprogramme ses rappels.
    ///
    /// Une erreur de lecture laisse les rappels déjà programmés en place.
    ///
    /// - Parameter profile: compte connecté.
    static func refresh(for profile: SessionProfile) async {
        guard let reservations = try? await ReservationService.loadMine(clubId: profile.clubId, profileId: profile.id) else { return }
        await schedule(reservations)
    }

    /// Remplace tous les rappels de réservation par ceux des réservations
    /// données.
    ///
    /// Ne sont retenues que les réservations non annulées dont l'heure du
    /// rappel est encore à venir, les plus proches d'abord, au plus
    /// `maxScheduled`. Rien n'est posé si les rappels sont coupés ou si les
    /// notifications ne sont pas autorisées (les anciens sont tout de même
    /// effacés).
    ///
    /// - Parameter reservations: réservations du membre.
    static func schedule(_ reservations: [MyReservation]) async {
        // On repart toujours d'une liste vide : une réservation annulée ou
        // déplacée ne garde pas son ancien rappel.
        await clear()
        guard isEnabled else { return }

        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        // Heure de début calculée dans le fuseau de l'appareil.
        let now = Date.now
        let upcoming = reservations
            .filter { !$0.isCancelled && $0.startsAt.addingTimeInterval(-leadTime) > now }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(maxScheduled)

        for reservation in upcoming {
            // « Padel à 18 h 30 », puis « Padel 2 · dans une heure. Bon match ! ».
            let content = UNMutableNotificationContent()
            content.title = "\(reservation.sport?.displayName ?? "Réservation") à \(reservation.slot.startLabel)"
            content.body = "\(reservation.courtName) · dans une heure. Bon match !"
            content.sound = .default
            content.userInfo = ["type": kind, "reservation_id": reservation.id.uuidString]

            // Déclenchement à la minute près, une heure avant le début.
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
    ///
    /// - Parameter reservationId: réservation concernée.
    static func cancel(reservationId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prefix + reservationId.uuidString])
    }

    /// À la déconnexion, ou quand le membre coupe les rappels.
    /// Ne retire que les rappels de réservation (préfixe `resa-`), pas les
    /// rappels d'appel.
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
