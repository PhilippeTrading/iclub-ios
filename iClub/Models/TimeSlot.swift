//
//  TimeSlot.swift
//  iClub
//
//  Un créneau de la grille horaire. Début et durée sont exprimés en minutes
//  depuis minuit : c'est la seule unité de comparaison fiable entre les formats
//  que Postgres renvoie pour une colonne `time` (« 14:00:00 » ou « 14:00 »).
//
//  La durée n'est pas une propriété du sport : elle vient du terrain
//  (`courts.duree_creneau_minutes`) et deux terrains d'un même sport peuvent en
//  théorie différer. Un créneau est donc identifié par le couple
//  (début, durée), jamais par le seul début.
//
//  Place dans l'application
//    Grille du planning (`AvailabilityEngine`), réservations du membre
//    (`MyReservation`), séances de cours (`ActivitySession`), écriture d'une
//    réservation (`postgresStart`, `postgresEnd`).
//
//  Points d'attention
//    Rien ne gère le passage de minuit : au-delà, `postgresEnd` produirait par
//    exemple « 25:00:00 », que refuse une colonne `time`. La grille du planning,
//    bornée par les horaires du club, ne crée pas de tel créneau.
//

import Foundation

/// Créneau horaire : heure de début et durée, en minutes.
nonisolated struct TimeSlot: Hashable, Sendable, Comparable {
    /// Début, en minutes depuis minuit (840 pour 14 h).
    let startMinutes: Int
    /// Durée, en minutes.
    let durationMinutes: Int

    /// Fin, en minutes depuis minuit (début plus durée).
    var endMinutes: Int { startMinutes + durationMinutes }

    /// Heure de début et heure de fin, par exemple « 14 h 00 » et « 15 h 00 »
    /// reliés par un tiret.
    var label: String {
        "\(Self.clock(startMinutes)) – \(Self.clock(endMinutes))"
    }

    /// « 14 h 00 ».
    var startLabel: String { Self.clock(startMinutes) }

    /// Heure lisible à la française. L'espace est une espace fine insécable
    /// (U+202F) : l'heure ne se coupe donc jamais en fin de ligne.
    ///
    /// - Parameter minutes: minutes depuis minuit.
    /// - Returns: heures et minutes sur deux chiffres, séparées par « h ».
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d\u{202F}h\u{202F}%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Écriture Postgres

    /// Format attendu par une colonne `time` en écriture.
    /// Début du créneau, « 14:00:00 ».
    var postgresStart: String { Self.postgresTime(startMinutes) }
    /// Fin du créneau, même format (`reservations.heure_fin`).
    var postgresEnd: String { Self.postgresTime(endMinutes) }

    /// - Parameter minutes: minutes depuis minuit.
    /// - Returns: « HH:MM:00 ».
    private static func postgresTime(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    // MARK: - Comparable

    /// Tri par heure de début, puis par durée à début égal.
    static func < (lhs: TimeSlot, rhs: TimeSlot) -> Bool {
        (lhs.startMinutes, lhs.durationMinutes) < (rhs.startMinutes, rhs.durationMinutes)
    }
}
