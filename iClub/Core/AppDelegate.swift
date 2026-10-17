//
//  AppDelegate.swift
//  iClub
//
//  Ce que SwiftUI ne couvre pas seul : le délégué des notifications, et la
//  reprise de la surveillance de zone dès le lancement.
//
//  Quand iOS relance l'app en arrière-plan pour un événement de zone, aucune
//  scène ne s'affiche : c'est ici, au tout début, que la surveillance doit être
//  recréée pour que l'événement soit reçu.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await ReengagementService.resumeZoneMonitoring() }
        return true
    }

    /// Affichée même si l'app est ouverte : le membre est sur l'app, mais pas
    /// forcément sur l'onglet des parties.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Un tap ouvre l'onglet des parties ouvertes, où la partie suggérée est
    /// visible et rejoignable.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { ReengagementService.requestOpenGames() }
    }
}
