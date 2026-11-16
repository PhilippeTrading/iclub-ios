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
//  Aucune notification locale n'est posée pour les parties ouvertes : elle
//  échapperait aux plafonds comptés en base. Les rappels de réservation
//  (`BookingReminders`) et d'appel (`AttendanceReminders`), eux, sont des
//  notifications locales programmées sur l'appareil ; leur tap passe aussi par
//  `handleTap`.
//
//  Place dans l'application
//    `AppDelegate` (jeton, présentation au premier plan, tap), `AuthController`
//    (jeton rattaché à la connexion), `AuthService` (appareil oublié à la
//    déconnexion et à la suppression du compte), écran d'explication
//    (`NotificationOptIn`), réglage du profil (`GameNotificationsSection`),
//    `MainTabView` (ouverture de l'écran visé, y compris au lancement à froid).
//
//  Tables et fonctions SQL (migration `20261017120000_notifications_habitudes.sql`)
//    - `enregistrer_appareil(device_token)` : rattache le jeton à l'utilisateur
//      connecté (table `notification_devices`, unicité sur le jeton : un jeton
//      déjà connu change de propriétaire).
//    - `oublier_appareil(device_token)` : supprime la ligne si elle appartient
//      à l'appelant.
//    - `notification_vue(target_reservation_id)` : date l'ouverture dans
//      `notifications_envoyees`.
//    - Table `profiles`, colonne `notifications_parties` (RLS : sa propre ligne).
//
//  Stockage local
//    `UserDefaults` : dernier jeton APNs reçu (`push.deviceToken`), conservé à
//    la déconnexion pour être rattaché au prochain compte, et date du dernier
//    refus de l'écran d'explication (`push.optInDeclinedAt`).
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet) : `UIApplication` et
//    les propriétés statiques en attente y sont lues et écrites sans course.
//

import Foundation
import Supabase
import UIKit
import UserNotifications

/// Notifications : jeton d'appareil, autorisation, routage des taps, réglage.
enum PushService {

    /// Émise quand le membre tape sur une notification de partie.
    static let openGameRequested = Notification.Name("iclub.openGameRequested")
    /// Émise quand l'entraîneur touche le rappel « faire l'appel ».
    static let attendanceRequested = Notification.Name("iclub.attendanceRequested")
    /// Émise quand le membre touche un rappel de réservation.
    static let bookingReminderRequested = Notification.Name("iclub.bookingReminderRequested")
    /// Émise quand le membre vient d'accepter les notifications : les rappels
    /// programmés sur l'appareil peuvent l'être maintenant.
    static let authorizationGranted = Notification.Name("iclub.notificationsAuthorized")

    /// Clés `UserDefaults`.
    private enum Key {
        /// Dernier jeton APNs, en hexadécimal.
        static let deviceToken = "push.deviceToken"
        /// Date du dernier « Pas maintenant » sur l'écran d'explication.
        static let optInDeclinedAt = "push.optInDeclinedAt"
    }

    /// Réglages persistants de l'app.
    private static var defaults: UserDefaults { .standard }

    // MARK: - Jeton d'appareil

    /// À chaque lancement : le jeton peut changer, et un jeton périmé est une
    /// notification perdue. iOS délivre un jeton même sans autorisation
    /// d'affichage : on l'enregistre donc pour tout membre, y compris celui qui
    /// n'a jamais réservé ni rejoint de partie. Rien n'est demandé au membre.
    ///
    /// La réponse arrive par `AppDelegate`, puis `didReceive(deviceToken:)`.
    static func refreshRegistration() async {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Retour de l'enregistrement APNs.
    ///
    /// - Parameter deviceToken: jeton binaire fourni par iOS ; mémorisé en
    ///   hexadécimal (deux caractères par octet) puis rattaché au membre.
    static func didReceive(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: Key.deviceToken)
        await registerCurrentToken()
    }

    /// Rattache le jeton connu au membre connecté. Appelé aussi à la connexion :
    /// le jeton peut être arrivé avant la session.
    ///
    /// Sans jeton ou sans session, ne fait rien ; une erreur est ignorée (le
    /// prochain lancement retentera).
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
    ///
    /// Efface aussi la date de refus de l'écran d'explication et la partie en
    /// attente d'ouverture. Le jeton reste mémorisé sur l'appareil.
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
    /// (7 jours de 86 400 secondes.)
    private static let optInRetryDelay: TimeInterval = 7 * 86_400

    /// Faut-il présenter notre écran d'explication ?
    ///
    /// Seulement tant qu'iOS n'a jamais posé la question : après un oui comme
    /// après un non, la fenêtre système ne se représentera plus, et insister
    /// dégraderait l'expérience.
    ///
    /// - Parameter now: instant de référence, injectable pour les essais.
    /// - Returns: `true` si la question système n'a jamais été posée et que le
    ///   dernier « Pas maintenant » date d'au moins 7 jours (ou n'existe pas).
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
    ///
    /// - Returns: `true` si le membre a accepté (bannières, sons, pastille).
    ///   Une erreur de la demande compte comme un refus.
    @discardableResult
    static func requestSystemAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        defaults.removeObject(forKey: Key.optInDeclinedAt)
        if granted {
            // Nouvel enregistrement APNs, et signal aux écrans qui attendaient
            // l'autorisation pour programmer leurs rappels locaux.
            UIApplication.shared.registerForRemoteNotifications()
            NotificationCenter.default.post(name: authorizationGranted, object: nil)
        }
        return granted
    }

    // MARK: - Ouverture depuis une notification

    /// Gardée en mémoire : quand la notification lance l'app à froid, l'onglet
    /// des parties n'existe pas encore au moment du tap.
    private static var pendingGameId: UUID?
    /// Séance dont l'appel est à ouvrir (rappel de l'entraîneur), en attente.
    private static var pendingAttendanceSessionId: UUID?
    /// Un rappel de réservation a été touché et n'a pas encore été traité.
    private static var pendingBookingReminder = false

    /// Lit et efface le rappel de réservation en attente.
    ///
    /// - Returns: `true` si un rappel avait été touché.
    static func consumePendingBookingReminder() -> Bool {
        defer { pendingBookingReminder = false }
        return pendingBookingReminder
    }

    /// Lit et efface la séance d'appel en attente.
    ///
    /// - Returns: la séance à ouvrir, ou `nil`.
    static func consumePendingAttendance() -> UUID? {
        defer { pendingAttendanceSessionId = nil }
        return pendingAttendanceSessionId
    }

    /// Aiguille le tap sur une notification vers l'écran concerné.
    ///
    /// L'ordre des tests compte : un rappel de réservation porte aussi un
    /// `reservation_id`, il doit être reconnu avant le cas « partie ouverte ».
    ///
    /// - Parameter userInfo: charge utile de la notification (copie à plat
    ///   faite par `PushPayload`).
    static func handleTap(userInfo: [AnyHashable: Any]) {
        // Rappel de réservation : l'historique de ses réservations.
        if (userInfo["type"] as? String) == BookingReminders.kind {
            pendingBookingReminder = true
            NotificationCenter.default.post(name: bookingReminderRequested, object: nil)
            return
        }

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

        // Sinon : proposition de partie ouverte, reconnue à son identifiant
        // de réservation. Sans identifiant, le tap n'ouvre rien.
        guard let gameId = reservationId(in: userInfo) else { return }
        pendingGameId = gameId
        NotificationCenter.default.post(name: openGameRequested, object: nil)
        // La mesure ne doit pas dépendre de l'affichage : on la signale dès le
        // tap, que l'écran de la partie parvienne à s'ouvrir ou non.
        Task { await markSeen(gameId) }
    }

    /// Lit et efface la partie en attente d'ouverture.
    ///
    /// - Returns: la réservation de la partie à ouvrir, ou `nil`.
    static func consumePendingGame() -> UUID? {
        defer { pendingGameId = nil }
        return pendingGameId
    }

    /// Clés acceptées pour l'identifiant de la réservation, au premier niveau
    /// de la charge utile ou sous `data`.
    private static let reservationKeys = ["reservation_id", "target_reservation_id", "reservationId"]

    /// - Parameter userInfo: charge utile.
    /// - Returns: le premier identifiant de réservation valide trouvé, en
    ///   cherchant d'abord au premier niveau puis sous `data`.
    static func reservationId(in userInfo: [AnyHashable: Any]) -> UUID? {
        let levels: [[AnyHashable: Any]] = [userInfo, userInfo["data"] as? [AnyHashable: Any] ?? [:]]
        for level in levels {
            for key in reservationKeys {
                if let raw = level[key] as? String, let id = UUID(uuidString: raw) { return id }
            }
        }
        return nil
    }

    /// - Parameter userInfo: charge utile.
    /// - Returns: `true` pour une notification de message (`type = message`,
    ///   posé par la fonction serveur `push-message`).
    static func isMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["type"] as? String) == "message"
    }

    /// - Parameter userInfo: charge utile.
    /// - Returns: la conversation d'une notification de message, ou `nil`.
    static func conversationId(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Faut-il afficher une notification reçue app ouverte ? Non si elle
    /// concerne la conversation déjà à l'écran : le message y apparaît en
    /// temps réel.
    ///
    /// - Parameter userInfo: charge utile.
    /// - Returns: `false` seulement pour un message de la conversation visible.
    static func shouldPresentInForeground(userInfo: [AnyHashable: Any]) -> Bool {
        guard isMessage(userInfo), let id = conversationId(in: userInfo) else { return true }
        return MessagingCenter.shared.visibleConversationId != id
    }

    /// Signale à la base que la notification de cette partie a été ouverte
    /// (`notification_vue`). Sans session, ou en cas d'erreur, rien.
    ///
    /// - Parameter gameId: réservation de la partie ouverte.
    private static func markSeen(_ gameId: UUID) async {
        guard (try? await Supa.client.auth.session) != nil else { return }
        _ = try? await Supa.client
            .rpc("notification_vue", params: ReservationParam(targetReservationId: gameId))
            .execute()
    }

    // MARK: - Réglage du membre

    /// `profiles.notifications_parties`. Distinct de l'autorisation système :
    /// couper les propositions ne coupe pas les messages importants.
    ///
    /// - Parameter profileId: profil du membre connecté.
    /// - Returns: la valeur enregistrée, `true` si la ligne n'est pas lisible.
    /// - Throws: l'erreur brute de la requête.
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

    /// Enregistre le choix du membre.
    ///
    /// - Parameters:
    ///   - enabled: `true` pour recevoir les propositions de parties.
    ///   - profileId: profil du membre connecté.
    /// - Throws: `SessionProfileError.updateRejected` si aucune ligne n'a été
    ///   modifiée, ou l'erreur brute de la requête.
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

    /// Paramètre de `enregistrer_appareil` et `oublier_appareil`.
    private nonisolated struct DeviceTokenParam: Encodable, Sendable {
        /// `device_token` : jeton APNs en hexadécimal.
        let deviceToken: String
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case deviceToken = "device_token" }
    }

    /// Paramètre de `notification_vue`.
    private nonisolated struct ReservationParam: Encodable, Sendable {
        /// `target_reservation_id`.
        let targetReservationId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case targetReservationId = "target_reservation_id" }
    }

    /// Lecture et écriture de `profiles.notifications_parties`.
    private nonisolated struct PreferenceRow: Codable, Sendable {
        /// `notifications_parties`.
        let notificationsParties: Bool
        /// Nom de la colonne SQL.
        enum CodingKeys: String, CodingKey { case notificationsParties = "notifications_parties" }
    }
}
