//
//  ReengagementService.swift
//  iClub
//
//  Suggestions de parties aux membres qui ne jouent plus.
//
//  Déclencheurs :
//    • un rafraîchissement périodique en arrière-plan — le principal, car un
//      membre habite presque toujours dans la zone et n'y « entre » donc que
//      rarement ;
//    • l'entrée dans la zone du club, au retour d'un voyage.
//
//  À chaque déclenchement, `evaluate()` lit les réservations et les parties
//  ouvertes, applique `ReengagementPolicy`, et pose une notification LOCALE si
//  tout est réuni. Aucun serveur n'est impliqué, aucune position n'est envoyée.
//

import BackgroundTasks
import CoreLocation
import Foundation
import Supabase
import UserNotifications

enum ReengagementService {

    static let refreshTaskID = "dev.iclub.io.iClub.reengagement"
    static let openGamesRequested = Notification.Name("iclub.openGamesRequested")

    // MARK: - Préférences (sur l'appareil)

    private enum Key {
        static let enabled = "reengagement.enabled"
        static let usesLocation = "reengagement.usesLocation"
        static let state = "reengagement.state"
        static let firstSeen = "reengagement.firstSeen"
        static let pendingOpenGames = "reengagement.pendingOpenGames"
    }

    private static var defaults: UserDefaults { .standard }

    /// « Me suggérer des parties ». Désactivé par défaut : c'est le membre qui
    /// choisit de recevoir ces notifications.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// « Seulement si je suis dans la région du club ».
    static var usesLocation: Bool {
        get { defaults.bool(forKey: Key.usesLocation) }
        set { defaults.set(newValue, forKey: Key.usesLocation) }
    }

    private static var state: ReengagementState {
        get {
            guard let data = defaults.data(forKey: Key.state),
                  let value = try? JSONDecoder().decode(ReengagementState.self, from: data)
            else { return ReengagementState() }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.state) }
    }

    /// Départ du décompte pour un membre qui n'a encore jamais joué.
    private static var firstSeen: Date {
        if let date = defaults.object(forKey: Key.firstSeen) as? Date { return date }
        let now = Date.now
        defaults.set(now, forKey: Key.firstSeen)
        return now
    }

    // MARK: - Activation

    /// - Returns: `false` si le membre refuse les notifications.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isEnabled = granted
        if granted { scheduleRefresh() }
        return granted
    }

    static func disable() async {
        isEnabled = false
        await setUsesLocation(false)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
    }

    static func setUsesLocation(_ value: Bool) async {
        usesLocation = value
        if value {
            ZoneMonitor.shared.requestAlwaysAuthorization()
            await resumeZoneMonitoring()
        } else {
            await ZoneMonitor.shared.stop()
        }
    }

    /// À la déconnexion ou à la suppression du compte : le suivant qui se
    /// connecte sur cet appareil repart de zéro.
    static func reset() async {
        await disable()
        for key in [Key.state, Key.firstSeen, Key.pendingOpenGames] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Lancement

    /// Recrée la surveillance de zone. Appelé au lancement, y compris quand iOS
    /// relance l'app en arrière-plan pour un événement de zone.
    static func resumeZoneMonitoring() async {
        guard isEnabled, usesLocation else { return }
        guard let center = await clubCoordinate() else { return }

        ZoneMonitor.shared.onEnterZone = { await evaluate() }
        await ZoneMonitor.shared.start(center: center)
    }

    /// Demande à iOS un réveil en arrière-plan d'ici une demi-journée. iOS
    /// décide du moment réel, selon l'usage de l'app et la batterie.
    static func scheduleRefresh() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date.now.addingTimeInterval(12 * 3600)
        // Un échec ici (simulateur, rafraîchissement désactivé dans Réglages)
        // n'a pas d'autre conséquence que l'absence de réveil.
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    // MARK: - Évaluation

    /// Décide s'il faut suggérer une partie, et pose la notification.
    ///
    /// Doit rester sobre : réveillée en arrière-plan, l'app n'a que quelques
    /// secondes. Tout échec réseau arrête simplement l'évaluation.
    static func evaluate(now: Date = .now) async {
        guard isEnabled else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        guard let session = try? await Supa.client.auth.session,
              let profile = try? await ProfileService.loadSessionProfile(
                  userId: session.user.id,
                  email: session.user.email ?? ""
              ),
              let reservations = try? await ReservationService.loadMine(
                  clubId: profile.clubId,
                  profileId: profile.id
              )
        else { return }

        let history = ReengagementPolicy.history(from: reservations, now: now)
        let zone: ZoneState = usesLocation ? await ZoneMonitor.shared.currentState() : .unknown
        let start = firstSeen

        guard ReengagementPolicy.decide(
            history: history, state: state, zone: zone, firstSeen: start, now: now
        ) == .remind else { return }

        // On ne relance jamais pour rien : sans partie concrète, on attend, et
        // la tentative ne compte pas.
        guard let games = try? await OpenGameService.loadAll(clubId: profile.clubId),
              let game = ReengagementPolicy.bestGame(among: games, profile: profile, history: history)
        else { return }

        let text = ReengagementPolicy.notificationContent(for: game)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = ["gameId": game.id.uuidString]

        let request = UNNotificationRequest(identifier: "reengagement-\(game.id)", content: content, trigger: nil)
        guard (try? await UNUserNotificationCenter.current().add(request)) != nil else { return }

        state = ReengagementPolicy.recordingReminder(state, history: history, firstSeen: start, now: now)
    }

    // MARK: - Ouverture depuis la notification

    /// Mémorisé pour le cas où la notification lance l'app à froid : l'onglet
    /// n'existe pas encore au moment du tap.
    static func requestOpenGames() {
        defaults.set(true, forKey: Key.pendingOpenGames)
        NotificationCenter.default.post(name: openGamesRequested, object: nil)
    }

    static func consumePendingOpenGames() -> Bool {
        let pending = defaults.bool(forKey: Key.pendingOpenGames)
        defaults.removeObject(forKey: Key.pendingOpenGames)
        return pending
    }

    // MARK: - Club

    private nonisolated struct ClubLocationRow: Decodable, Sendable {
        let latitude: Double?
        let longitude: Double?
    }

    /// Lue en base plutôt que figée dans l'app : l'admin peut la corriger sans
    /// nouvelle version. `nil` si elle n'est pas renseignée — la zone est
    /// alors simplement inconnue, ce qui n'empêche aucune suggestion.
    static func clubCoordinate() async -> CLLocationCoordinate2D? {
        guard let clubId = AppConfiguration.clubId,
              let rows: [ClubLocationRow] = try? await Supa.client
                .from("clubs")
                .select("latitude, longitude")
                .eq("id", value: clubId.uuidString)
                .limit(1)
                .execute()
                .value,
              let latitude = rows.first?.latitude,
              let longitude = rows.first?.longitude
        else { return nil }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
