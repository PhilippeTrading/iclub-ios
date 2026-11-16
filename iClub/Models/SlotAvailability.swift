//
//  SlotAvailability.swift
//  iClub
//
//  Résultat du calcul de disponibilité : pour chaque créneau, l'état de chacun
//  des terrains du sport. Le filtre de surface n'est *pas* appliqué ici : il est
//  purement d'affichage et change sans relire la base.
//
//  Place dans l'application
//    Produit par `AvailabilityEngine.slots`, affiché par l'écran des créneaux
//    (`BookingView`, une ligne par créneau) et par le choix du terrain
//    (`CourtPickerView`).
//
//  Points d'attention
//    Types calculés en mémoire, jamais décodés ni écrits en base.
//

import Foundation

/// État d'un terrain sur un créneau.
enum CourtAvailability: Hashable, Sendable {
    /// Libre : réservable.
    case available
    /// Raison affichée en gris : « Réservé », « Entretien », « Cours »…
    case unavailable(reason: String)

    /// `true` pour un terrain libre.
    var isAvailable: Bool {
        if case .available = self { true } else { false }
    }

    /// Raison de l'indisponibilité, `nil` pour un terrain libre.
    var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}

/// Un terrain et son état sur un créneau donné.
struct CourtSlotState: Identifiable, Hashable, Sendable {
    /// Terrain concerné.
    let court: Court
    /// Son état sur le créneau.
    let availability: CourtAvailability

    /// Identifiant de liste : celui du terrain (unique dans un créneau).
    var id: UUID { court.id }
    /// Raccourci de `availability.isAvailable`.
    var isAvailable: Bool { availability.isAvailable }
}

/// Un créneau de la grille et l'état de chaque terrain du sport.
struct SlotAvailability: Identifiable, Hashable, Sendable {
    /// Créneau (début et durée).
    let slot: TimeSlot
    /// Tous les terrains du sport concernés par ce créneau, dans l'ordre
    /// `courts.ordre` voulu par l'admin.
    let courts: [CourtSlotState]

    /// Identifiant de liste : le créneau lui-même (couple début, durée).
    var id: TimeSlot { slot }

    /// Terrains retenus par le filtre de surface actif. `nil` = « Tout ».
    ///
    /// - Parameter surface: libellé exact de `courts.surface`, ou `nil`.
    /// - Returns: les terrains du créneau ayant cette surface.
    func courts(surface: String?) -> [CourtSlotState] {
        guard let surface else { return courts }
        return courts.filter { $0.court.surface == surface }
    }

    /// Terrains libres du créneau, filtre de surface appliqué.
    ///
    /// - Parameter surface: filtre actif, `nil` pour tous.
    /// - Returns: les terrains réservables à afficher.
    func availableCourts(surface: String?) -> [CourtSlotState] {
        courts(surface: surface).filter(\.isAvailable)
    }
}
