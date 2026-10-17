//
//  DateFormatting.swift
//  iClub
//
//  Toute l'interface est en français : les dates sont formatées en fr_FR quelle
//  que soit la langue de l'appareil, pour éviter un écran mi-français mi-anglais.
//

import Foundation

/// `nonisolated` : `Locale` est une valeur `Sendable`, et les DTO décodés hors
/// de l'acteur principal doivent pouvoir formater en français.
nonisolated enum AppLocale {
    static let french = Locale(identifier: "fr_FR")
}

extension Date {

    /// « mercredi 22 septembre 2026 », première lettre en capitale.
    var longFrenchDate: String {
        let value = formatted(
            Date.FormatStyle(date: .complete, time: .omitted)
                .locale(AppLocale.french)
        )
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    /// « 22 septembre 2026 ».
    var mediumFrenchDate: String {
        formatted(
            Date.FormatStyle(date: .long, time: .omitted)
                .locale(AppLocale.french)
        )
    }

    /// « 22 sept. ».
    var shortFrenchDate: String {
        formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(AppLocale.french)
        )
    }

    /// « lun. » — abrégé du jour de la semaine, pour la bande de jours.
    var frenchWeekdayAbbreviation: String {
        formatted(
            Date.FormatStyle(date: .omitted, time: .omitted)
                .weekday(.abbreviated)
                .locale(AppLocale.french)
        )
    }

    /// « 22 » — numéro du jour dans le mois, sans le mois ni l'année.
    var frenchDayNumber: String {
        formatted(
            Date.FormatStyle(date: .omitted, time: .omitted)
                .day()
                .locale(AppLocale.french)
        )
    }
}
