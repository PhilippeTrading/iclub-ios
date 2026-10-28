//
//  PushService.swift
//  iClub
//
//  Notifications de parties ouvertes, envoyées par le serveur.
//
//  Tout le ciblage vit en base (habitudes, plafonds, choix des destinataires) :
//  l'app ne décide rien et ne recalcule rien. Son rôle se limite à :
//    • demander l'autorisation au bon moment ;
//    • enregistrer le jeton d'appareil, et l'oublier à la déconnexion ;
//    • porter le réglage `profiles.notifications_parties` ;
//    • ouvrir la partie annoncée, et signaler l'ouverture (`notification_vue`).
//
//  Aucune notification locale n'est jamais posée : elle échapperait aux
//  plafonds comptés en base.
//

import Foundation
import Supabase
import UIKit
import UserNotifications

enum PushService {

    /// Émise quand le membre tape sur une notification de partie.
    static let openGameRequested = Notification.Name("iclub.openGameRequested")
    /// Émise quand l'entraîneur touche le rappel « faire l'appel ».
    static let attendanceRequested = Notification.Name("iclub.attendanceRequested")
    /// Émise quand le membre vient d'accepter les notifications : les rappels
    /// programmés sur l'appareil peuvent l'être maintenant.
    static let authorizationGranted = Notification.Name("iclub.notificationsAuthorized")

    private enum Key {
        static let deviceToken = "push.deviceToken"
        static let optInDeclinedAt = "push.optInDeclinedAt"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Jeton d'appareil

    /// À chaque lancement : le jeton peut changer, et un jeton périmé est une
    /// notification perdue. iOS délivre un jeton même sans autorisation
    /// d'affichage : on l'enregistre donc pour tout membre, y compris celui qui
    /// n'a jamais réservé ni rejoint de partie. Rien n'est demandé au membre.
    static func refreshRegistration() async {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Retour de l'enregistrement APNs.
    static func didReceive(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: Key.deviceToken)
        await registerCurrentToken()
    }

    /// Rattache le jeton connu au membre connecté. Appelé aussi à la connexion :
    /// le jeton peut être arrivé avant la session.
    static func registerCurrentToken() async {
        guard let token = defaults.string(forKey: Key.deviceToken),
              (try? await Supa.client.auth.session) != nil
        else { return }

        _ = try? await Supa.client
            .rpc("enregistrer_appareil", params: DeviceTokenParam(deviceToken: token))
            .execute()
    }

    /// À la déconnexion et avant la suppression du compte, **tant que la
    /// session est valide** : sans cela, le prochain membre à se connecter sur
    /// ce téléphone recevrait les notifications du précédent.
    static func forgetDevice() async {
        if let token = defaults.string(forKey: Key.deviceToken) {
            _ = try? await Supa.client
                .rpc("oublier_appareil", params: DeviceTokenParam(deviceToken: token))
                .execute()
        }
        defaults.removeObject(forKey: Key.optInDeclinedAt)
        pendingGameId = nil
    }

    // MARK: - Autorisation

    /// Délai avant de reproposer notre écran à un membre qui l'a décliné.
    private static let optInRetryDelay: TimeInterval = 7 * 86_400

    /// Faut-il présenter notre écran d'explication ?
    ///
    /// Seulement tant qu'iOS n'a jamais posé la question : après un oui comme
    /// après un non, la fenêtre système ne se représentera plus, et insister
    /// dégraderait l'expérience.
    static func shouldOfferOptIn(now: Date = .now) async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .notDetermined else { return false }

        guard let declinedAt = defaults.object(forKey: Key.optInDeclinedAt) as? Date else { return true }
        return now.timeIntervalSince(declinedAt) >= optInRetryDelay
    }

    /// « Pas maintenant » sur notre écran : la demande système n'est pas
    /// présentée, l'unique chance offerte par iOS reste intacte.
    static func declineOptIn() {
        defaults.set(Date.now, forKey: Key.optInDeclinedAt)
    }

    /// Présente la demande système. Uniquement après un « oui » du membre sur
    /// notre écran, ou sur son geste explicite dans le profil.
    @discardableResult
    static func requestSystemAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        defaults.removeObject(forKey: Key.optInDeclinedAt)
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
            NotificationCenter.default.post(name: authorizationGranted, object: nil)
        }
        return granted
    }

    // MARK: - Ouverture depuis une notification

    /// Gardée en mémoire : quand la notification lance l'app à froid, l'onglet
    /// des parties n'existe pas encore au moment du tap.
    private static var pendingGameId: UUID?
    private static var pendingAttendanceSessionId: UUID?

    static func consumePendingAttendance() -> UUID? {
        defer { pendingAttendanceSessionId = nil }
        return pendingAttendanceSessionId
    }

    static func handleTap(userInfo: [AnyHashable: Any]) {
        // Message : on ouvre directement la conversation. Elle se marque lue
        // en s'affichant.
        if isMessage(userInfo), let conversationId = conversationId(in: userInfo) {
            MessagingCenter.shared.open(conversationId: conversationId)
            return
        }

        // Rappel d'appel, programmé sur l'iPhone de l'entraîneur.
        if (userInfo["type"] as? String) == AttendanceReminders.kind,
           let raw = userInfo["seance_id"] as? String, let sessionId = UUID(uuidString: raw) {
            pendingAttendanceSessionId = sessionId
            NotificationCenter.default.post(name: attendanceRequested, object: nil)
            return
        }

        guard let gameId = reservationId(in: userInfo) else { return }
        pendingGameId = gameId
        NotificationCenter.default.post(name: openGameRequested, object: nil)
        // La mesure ne doit pas dépendre de l'affichage : on la signale dès le
        // tap, que l'écran de la partie parvienne à s'ouvrir ou non.
        Task { await markSeen(gameId) }
    }

    static func consumePendingGame() -> UUID? {
        defer { pendingGameId = nil }
        return pendingGameId
    }

    /// Clés acceptées pour l'identifiant de la réservation, au premier niveau
    /// de la charge utile ou sous `data`.
    private static let reservationKeys = ["reservation_id", "target_reservation_id", "reservationId"]

    static func reservationId(in userInfo: [AnyHashable: Any]) -> UUID? {
        let levels: [[AnyHashable: Any]] = [userInfo, userInfo["data"] as? [AnyHashable: Any] ?? [:]]
        for level in levels {
            for key in reservationKeys {
                if let raw = level[key] as? String, let id = UUID(uuidString: raw) { return id }
            }
        }
        return nil
    }

    static func isMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["type"] as? String) == "message"
    }

    static func conversationId(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Faut-il afficher une notification reçue app ouverte ? Non si elle
    /// concerne la conversation déjà à l'écran : le message y apparaît en
    /// temps réel.
    static func shouldPresentInForeground(userInfo: [AnyHashable: Any]) -> Bool {
        guard isMessage(userInfo), let id = conversationId(in: userInfo) else { return true }
        return MessagingCenter.shared.visibleConversationId != id
    }

    private static func markSeen(_ gameId: UUID) async {
        guard (try? await Supa.client.auth.session) != nil else { return }
        _ = try? await Supa.client
            .rpc("notification_vue", params: ReservationParam(targetReservationId: gameId))
            .execute()
    }

    // MARK: - Réglage du membre

    /// `profiles.notifications_parties`. Distinct de l'autorisation système :
    /// couper les propositions ne coupe pas les messages importants.
    static func loadPreference(profileId: UUID) async throws -> Bool {
        let rows: [PreferenceRow] = try await Supa.client
            .from("profiles")
            .select("notifications_parties")
            .eq("id", value: profileId.uuidString)
            .limit(1)
            .execute()
            .value
        // Vrai par défaut en base.
        return rows.first?.notificationsParties ?? true
    }

    static func savePreference(_ enabled: Bool, profileId: UUID) async throws {
        let updated: [PreferenceRow] = try await Supa.client
            .from("profiles")
            .update(PreferenceRow(notificationsParties: enabled))
            .eq("id", value: profileId.uuidString)
            .select("notifications_parties")
            .execute()
            .value

        // Une mise à jour refusée par les règles d'accès ne lève pas d'erreur :
        // elle ne touche simplement aucune ligne.
        guard !updated.isEmpty else { throw SessionProfileError.updateRejected }
    }

    // MARK: - Paramètres

    private nonisolated struct DeviceTokenParam: Encodable, Sendable {
        let deviceToken: String
        enum CodingKeys: String, CodingKey { case deviceToken = "device_token" }
    }

    private nonisolated struct ReservationParam: Encodable, Sendable {
        let targetReservationId: UUID
        enum CodingKeys: String, CodingKey { case targetReservationId = "target_reservation_id" }
    }

    private nonisolated struct PreferenceRow: Codable, Sendable {
        let notificationsParties: Bool
        enum CodingKeys: String, CodingKey { case notificationsParties = "notifications_parties" }
    }
}
