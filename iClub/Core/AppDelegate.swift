//
//  AppDelegate.swift
//  iClub
//
//  Ce que SwiftUI ne couvre pas seul : l'enregistrement APNs et le délégué
//  des notifications.
//
//  Rôle
//    Délégué UIKit de l'application, branché par `@UIApplicationDelegateAdaptor`
//    dans `iClubApp`. Il relaie à `PushService` les événements du système liés
//    aux notifications : jeton d'appareil reçu, notification arrivée app
//    ouverte, tap sur une notification.
//
//  Place dans l'application
//    Notifications distantes (APNs) envoyées par le serveur : messages
//    (fonction serveur `push-message`, déclenchée par une insertion dans
//    `messages`) et propositions de parties ouvertes (ciblage préparé en base
//    par `candidats_notification_partie` ; l'expéditeur de ces propositions ne
//    figure ni dans ce dépôt ni dans le dépôt web). Notifications locales
//    programmées par l'app elle-même : rappels de réservation
//    (`BookingReminders`) et rappels d'appel de l'entraîneur
//    (`AttendanceReminders`). Les deux familles passent par les mêmes méthodes
//    de délégué ci-dessous.
//
//  Effets de bord
//    Demande de jeton APNs à chaque lancement ; aucune écriture en base ici
//    (c'est `PushService` qui enregistre le jeton et signale les ouvertures).
//
//  Fil d'exécution
//    Les méthodes du délégué des notifications sont `nonisolated` (iOS les
//    appelle hors de l'acteur principal) ; elles repassent sur l'acteur
//    principal par `MainActor.run` pour appeler `PushService`.
//

import UIKit
import UserNotifications

/// Délégué de l'application et du centre de notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Lancement de l'app : se déclare délégué des notifications (sans quoi
    /// une notification arrivée app ouverte ne s'afficherait pas, et un tap ne
    /// serait pas relayé) puis demande le jeton APNs.
    ///
    /// - Returns: toujours `true`, le lancement continue normalement.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Le jeton est redemandé à chaque lancement : il peut changer.
        Task { await PushService.refreshRegistration() }
        return true
    }

    /// Jeton APNs reçu : `PushService` le mémorise et le rattache au membre
    /// connecté (fonction SQL `enregistrer_appareil`).
    ///
    /// - Parameter deviceToken: jeton binaire fourni par iOS, converti en
    ///   hexadécimal par `PushService.didReceive(deviceToken:)`.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushService.didReceive(deviceToken: deviceToken) }
    }

    /// Simulateur, ou capacité Push absente du profil de signature : sans
    /// jeton, l'app fonctionne normalement, simplement sans notifications.
    /// L'erreur est volontairement ignorée.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}

    /// App au premier plan : une bannière sur laquelle taper, rien qui surgisse
    /// par-dessus ce que le membre est en train de faire, et rien du tout si
    /// le message concerne la conversation déjà ouverte.
    ///
    /// - Returns: bannière, liste et son ; ou rien si `PushService` juge la
    ///   notification inutile (message de la conversation affichée).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Copie `Sendable` de la charge utile, pour la passer à l'acteur principal.
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        let shows = await MainActor.run { PushService.shouldPresentInForeground(userInfo: payload.userInfo) }
        return shows ? [.banner, .list, .sound] : []
    }

    /// Tap sur la notification, app fermée comme ouverte : on ouvre la partie,
    /// la conversation, l'historique des réservations ou l'appel concerné (le
    /// choix est fait par `PushService.handleTap`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        // Le dictionnaire n'est pas `Sendable` : on n'en transmet qu'une copie
        // de ses valeurs textuelles, faite de ce côté-ci.
        let payload = PushPayload(userInfo: userInfo)
        await MainActor.run { PushService.handleTap(userInfo: payload.userInfo) }
    }
}

/// Copie `Sendable` de ce dont `handleTap` a besoin.
///
/// Ne garde que les couples clé et valeur de type texte : les valeurs placées
/// sous la clé `data` de la charge utile, puis celles du premier niveau (qui
/// l'emportent en cas de doublon). Le dictionnaire `aps` et toute valeur non
/// textuelle (nombre, tableau) sont écartés.
nonisolated struct PushPayload: Sendable {
    /// Valeurs textuelles retenues, à plat.
    private let values: [String: String]

    /// - Parameter userInfo: charge utile brute de la notification (distante
    ///   ou locale).
    init(userInfo: [AnyHashable: Any]) {
        var values: [String: String] = [:]
        // Niveau imbriqué d'abord (`data`), puis premier niveau, qui écrase.
        let nested = userInfo["data"] as? [AnyHashable: Any] ?? [:]
        for (key, value) in nested { if let key = key as? String, let value = value as? String { values[key] = value } }
        for (key, value) in userInfo { if let key = key as? String, let value = value as? String { values[key] = value } }
        self.values = values
    }

    /// La copie remise sous la forme attendue par `PushService`. Comme les
    /// valeurs sont à plat, une clé lue sous `data` par `PushService` n'y est
    /// plus : elle se retrouve au premier niveau.
    var userInfo: [AnyHashable: Any] { values }
}
