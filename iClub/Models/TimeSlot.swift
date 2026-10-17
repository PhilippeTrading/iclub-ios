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

import Foundation

nonisolated struct TimeSlot: Hashable, Sendable, Comparable {
    let startMinutes: Int
    let durationMinutes: Int

    var endMinutes: Int { startMinutes + durationMinutes }

    /// « 14 h 00 – 15 h 00 ».
    var label: String {
        "\(Self.clock(startMinutes)) – \(Self.clock(endMinutes))"
    }

    /// « 14 h 00 ».
    var startLabel: String { Self.clock(startMinutes) }

    /// Heure lisible à la française. L'espace est une espace fine insécable
    /// (U+202F) : l'heure ne se coupe donc jamais en fin de ligne.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d\u{202F}h\u{202F}%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Écriture Postgres

    /// Format attendu par une colonne `time` en écriture.
    var postgresStart: String { Self.postgresTime(startMinutes) }
    var postgresEnd: String { Self.postgresTime(endMinutes) }

    private static func postgresTime(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    // MARK: - Comparable

    static func < (lhs: TimeSlot, rhs: TimeSlot) -> Bool {
        (lhs.startMinutes, lhs.durationMinutes) < (rhs.startMinutes, rhs.durationMinutes)
    }
}
