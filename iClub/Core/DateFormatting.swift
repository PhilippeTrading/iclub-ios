//
//  DateFormatting.swift
//  iClub
//
//  Toute l'interface est en français : les dates sont formatées en fr_FR quelle
//  que soit la langue de l'appareil, pour éviter un écran mi-français mi-anglais.
//
//  Place dans l'application
//    Utilisé par la plupart des écrans (accueil, bande de jours, réservations,
//    parties, cours, messagerie, profil). La locale `AppLocale.french` est aussi
//    injectée dans l'environnement SwiftUI par `iClubApp`, pour les contrôles
//    système.
//
//  Points d'attention
//    Les dates sont rendues dans le fuseau de l'appareil (réglage par défaut de
//    `Date.FormatStyle`), et non dans celui du club (`clubs.timezone`, Europe/Paris
//    par défaut) : un appareil réglé sur un autre fuseau verrait des jours décalés.
//

import Foundation

/// `nonisolated` : `Locale` est une valeur `Sendable`, et les DTO décodés hors
/// de l'acteur principal doivent pouvoir formater en français.
nonisolated enum AppLocale {
    /// Locale française de France, utilisée pour toutes les dates, heures,
    /// nombres et montants affichés.
    static let french = Locale(identifier: "fr_FR")
}

/// Formats de date en français, prêts à afficher.
extension Date {

    /// « mercredi 22 septembre 2026 », première lettre en capitale.
    var longFrenchDate: String {
        let value = formatted(
            Date.FormatStyle(date: .complete, time: .omitted)
                .locale(AppLocale.french)
        )
        // Le format français écrit le jour en minuscule : capitale ajoutée
        // pour un début de ligne ou un titre.
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

    /// « lun. » : abrégé du jour de la semaine, pour la bande de jours.
    var frenchWeekdayAbbreviation: String {
        formatted(
            Date.FormatStyle(date: .omitted, time: .omitted)
                .weekday(.abbreviated)
                .locale(AppLocale.french)
        )
    }

    /// « Aujourd'hui », « Demain », puis « Samedi 24 octobre » : pour séparer
    /// une liste par jour. « Aujourd'hui » et « Demain » suivent le calendrier
    /// de l'appareil.
    var relativeFrenchDayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Aujourd'hui" }
        if calendar.isDateInTomorrow(self) { return "Demain" }

        // Au-delà : jour de la semaine, quantième et mois, sans l'année.
        let value = formatted(
            Date.FormatStyle(date: .omitted, time: .omitted)
                .weekday(.wide)
                .day()
                .month(.wide)
                .locale(AppLocale.french)
        )
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    /// « 22 » : numéro du jour dans le mois, sans le mois ni l'année.
    var frenchDayNumber: String {
        formatted(
            Date.FormatStyle(date: .omitted, time: .omitted)
                .day()
                .locale(AppLocale.french)
        )
    }
}
