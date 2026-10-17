//
//  SlotAvailability.swift
//  iClub
//
//  Résultat du calcul de disponibilité : pour chaque créneau, l'état de chacun
//  des terrains du sport. Le filtre de surface n'est *pas* appliqué ici — il est
//  purement d'affichage et change sans relire la base.
//

import Foundation

enum CourtAvailability: Hashable, Sendable {
    case available
    /// Raison affichée en gris : « Réservé », « Entretien », « Cours »…
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { true } else { false }
    }

    var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}

struct CourtSlotState: Identifiable, Hashable, Sendable {
    let court: Court
    let availability: CourtAvailability

    var id: UUID { court.id }
    var isAvailable: Bool { availability.isAvailable }
}

struct SlotAvailability: Identifiable, Hashable, Sendable {
    let slot: TimeSlot
    /// Tous les terrains du sport concernés par ce créneau, dans l'ordre
    /// `courts.ordre` voulu par l'admin.
    let courts: [CourtSlotState]

    var id: TimeSlot { slot }

    /// Terrains retenus par le filtre de surface actif. `nil` = « Tout ».
    func courts(surface: String?) -> [CourtSlotState] {
        guard let surface else { return courts }
        return courts.filter { $0.court.surface == surface }
    }

    func availableCourts(surface: String?) -> [CourtSlotState] {
        courts(surface: surface).filter(\.isAvailable)
    }
}
