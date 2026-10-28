//
//  AppDelegate.swift
//  iClub
//
//  Ce que SwiftUI ne couvre pas seul : l'enregistrement APNs et le délégué
//  des notifications.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Le jeton est redemandé à chaque lancement : il peut changer.
        Task { await PushService.refreshRegistration() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushService.didReceive(deviceToken: deviceToken) }
    }

    /// Simulateur, ou capacité Push absente du profil de signature : sans
    /// jeton, l'app fonctionne normalement, simplement sans notifications.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}

    /// App au premier plan : une bannière sur laquelle taper, rien qui surgisse
    /// par-dessus ce que le membre est en train de faire — et rien du tout si
    /// le message concerne la conversation déjà ouverte.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        let shows = await MainActor.run { PushService.shouldPresentInForeground(userInfo: payload.userInfo) }
        return shows ? [.banner, .list, .sound] : []
    }

    /// Tap sur la notification, app fermée comme ouverte : on ouvre la partie
    /// ou la conversation concernée.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        // Le dictionnaire n'est pas `Sendable` : on n'en transmet que
        // l'identifiant, extrait de ce côté-ci.
        let payload = PushPayload(userInfo: userInfo)
        await MainActor.run { PushService.handleTap(userInfo: payload.userInfo) }
    }
}

/// Copie `Sendable` de ce dont `handleTap` a besoin.
nonisolated struct PushPayload: Sendable {
    private let values: [String: String]

    init(userInfo: [AnyHashable: Any]) {
        var values: [String: String] = [:]
        let nested = userInfo["data"] as? [AnyHashable: Any] ?? [:]
        for (key, value) in nested { if let key = key as? String, let value = value as? String { values[key] = value } }
        for (key, value) in userInfo { if let key = key as? String, let value = value as? String { values[key] = value } }
        self.values = values
    }

    var userInfo: [AnyHashable: Any] { values }
}
