//
//  ClubSportSettings.swift
//  iClub
//
//  Horaires d'ouverture et horizon de réservation, par club et par sport.
//  La grille du planning se construit de l'ouverture à la fermeture, par pas de
//  `courts.duree_creneau_minutes`.
//

import Foundation

struct ClubSportSettings: Hashable, Sendable {
    let sport: Sport
    /// Minutes depuis minuit, pour construire la grille sans manipuler de dates.
    let ouvertureMinutes: Int
    let fermetureMinutes: Int
    /// Nombre de jours réservables à l'avance.
    let horizonJours: Int

    /// Repli utilisé lorsque le club n'a pas de ligne pour ce sport : on
    /// n'empêche jamais l'affichage d'un sport qui a des terrains actifs.
    static func fallback(for sport: Sport) -> ClubSportSettings {
        ClubSportSettings(
            sport: sport,
            ouvertureMinutes: 9 * 60,
            fermetureMinutes: 21 * 60,
            horizonJours: 7
        )
    }
}

nonisolated struct ClubSportSettingsRow: Decodable, Sendable {
    let sport: String
    let heureOuverture: String?
    let heureFermeture: String?
    let horizonJours: Int?

    enum CodingKeys: String, CodingKey {
        case sport
        case heureOuverture = "heure_ouverture"
        case heureFermeture = "heure_fermeture"
        case horizonJours = "horizon_jours"
    }

    static let columns = "club_id, sport, heure_ouverture, heure_fermeture, horizon_jours"

    func toDomain() -> ClubSportSettings? {
        guard let sport = Sport(rawValue: sport.lowercased()) else { return nil }
        let fallback = ClubSportSettings.fallback(for: sport)

        return ClubSportSettings(
            sport: sport,
            ouvertureMinutes: Self.minutes(from: heureOuverture) ?? fallback.ouvertureMinutes,
            fermetureMinutes: Self.minutes(from: heureFermeture) ?? fallback.fermetureMinutes,
            horizonJours: horizonJours ?? fallback.horizonJours
        )
    }

    /// « 09:00:00 » ou « 09:00 » → minutes depuis minuit.
    static func minutes(from value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
