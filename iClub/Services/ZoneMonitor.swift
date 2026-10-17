//
//  ZoneMonitor.swift
//  iClub
//
//  Surveillance de la zone de 40 km autour du club.
//
//  La position ne quitte jamais le téléphone : iOS surveille lui-même la zone
//  et ne dit à l'app qu'une chose, « dedans » ou « dehors ». Aucune coordonnée
//  du membre n'est lue, stockée ni envoyée.
//
//  Elle sert de filtre — ne pas déranger un membre qu'on SAIT loin — et de
//  déclencheur au retour de voyage : quand il entre dans la zone, iOS relance
//  l'app en arrière-plan, qui évalue alors une éventuelle suggestion.
//

import CoreLocation
import Foundation
import Observation

@Observable
final class ZoneMonitor: NSObject {

    static let shared = ZoneMonitor()

    private static let monitorName = "iclub-club-zone"
    private static let conditionID = "club"

    private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?

    /// Appelé quand le membre entre dans la zone.
    var onEnterZone: (() async -> Void)?

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// « Toujours » est la seule autorisation qui permette de savoir où est
    /// le membre quand l'app est fermée. Avec « Pendant l'utilisation »,
    /// l'état de la zone peut être périmé : on le traite comme inconnu.
    var hasAlwaysAuthorization: Bool { authorization == .authorizedAlways }

    // MARK: - Autorisation

    /// iOS demande d'abord « Pendant l'utilisation », puis propose plus tard
    /// de passer à « Toujours ». Depuis « Pendant l'utilisation », ce même
    /// appel affiche la demande de passage à « Toujours », une seule fois.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    // MARK: - Surveillance

    /// À appeler au lancement — y compris quand iOS relance l'app en
    /// arrière-plan pour un événement de zone : recréer le moniteur sous le
    /// même nom est ce qui permet de recevoir l'événement.
    func start(center: CLLocationCoordinate2D) async {
        let monitor = await existingOrNewMonitor()
        let condition = CLMonitor.CircularGeographicCondition(center: center, radius: ReengagementPolicy.zoneRadius)

        // Ne recrée la condition que si le club a bougé : la recréer à chaque
        // lancement remettrait l'état à « inconnu ».
        if let record = await monitor.record(for: Self.conditionID),
           let current = record.condition as? CLMonitor.CircularGeographicCondition,
           current.center.latitude == center.latitude,
           current.center.longitude == center.longitude,
           current.radius == condition.radius {
            // Déjà en place.
        } else {
            await monitor.remove(Self.conditionID)
            await monitor.add(condition, identifier: Self.conditionID)
        }

        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            do {
                for try await event in await monitor.events where event.state == .satisfied {
                    await self?.onEnterZone?()
                }
            } catch {
                // Flux interrompu : la zone sera simplement considérée comme
                // inconnue, ce qui n'empêche aucune suggestion.
            }
        }
    }

    func stop() async {
        eventsTask?.cancel()
        eventsTask = nil
        // Le moniteur est recréé si besoin : la condition persiste entre deux
        // lancements, il faut pouvoir la retirer même au premier appel.
        let monitor = await existingOrNewMonitor()
        await monitor.remove(Self.conditionID)
    }

    /// Ce que l'on sait de la présence du membre dans la zone.
    func currentState() async -> ZoneState {
        guard hasAlwaysAuthorization, let monitor else { return .unknown }
        guard let record = await monitor.record(for: Self.conditionID) else { return .unknown }

        switch record.lastEvent.state {
        case .satisfied: return .inside
        case .unsatisfied: return .outside
        default: return .unknown
        }
    }

    private func existingOrNewMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(Self.monitorName)
        monitor = created
        return created
    }
}

extension ZoneMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
