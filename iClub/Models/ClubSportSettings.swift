//
//  ClubSportSettings.swift
//  iClub
//
//  Horaires d'ouverture et horizon de réservation, par club et par sport.
//  La grille du planning se construit de l'ouverture à la fermeture, par pas de
//  `courts.duree_creneau_minutes`.
//
//  Rôle
//    Type du domaine `ClubSportSettings` et ligne décodée
//    `ClubSportSettingsRow` de la table `club_sport_settings` (clé primaire
//    `club_id, sport`).
//
//  Place dans l'application
//    Lue par `PlanningService.loadSportSettings`, gardée par `ClubCatalog`,
//    utilisée par `AvailabilityEngine` (bornes de la grille), la bande de jours
//    (horizon) et l'accueil (heure de fermeture).
//
//  Droits et sécurité
//    Lecture publique (RLS `club_sport_settings_select_public`), écriture par
//    l'administration du club.
//

import Foundation

/// Horaires d'un sport dans le club.
struct ClubSportSettings: Hashable, Sendable {
    /// Sport concerné.
    let sport: Sport
    /// Minutes depuis minuit, pour construire la grille sans manipuler de dates.
    /// Heure d'ouverture (`heure_ouverture`).
    let ouvertureMinutes: Int
    /// Heure de fermeture (`heure_fermeture`), en minutes depuis minuit. Aucun
    /// créneau ne la dépasse.
    let fermetureMinutes: Int
    /// Nombre de jours réservables à l'avance.
    /// (`horizon_jours`, 7 par défaut en base.)
    let horizonJours: Int

    /// Repli utilisé lorsque le club n'a pas de ligne pour ce sport : on
    /// n'empêche jamais l'affichage d'un sport qui a des terrains actifs.
    ///
    /// - Parameter sport: sport sans réglage.
    /// - Returns: 9 h à 21 h, réservable 7 jours à l'avance (valeurs fixées
    ///   ici, pas lues en base).
    static func fallback(for sport: Sport) -> ClubSportSettings {
        ClubSportSettings(
            sport: sport,
            ouvertureMinutes: 9 * 60,
            fermetureMinutes: 21 * 60,
            horizonJours: 7
        )
    }
}

/// Ligne de `club_sport_settings`. Les colonnes `time` arrivent en texte
/// (« 09:00:00 »).
nonisolated struct ClubSportSettingsRow: Decodable, Sendable {
    /// `sport`, valeur brute.
    let sport: String
    /// `heure_ouverture` (`time`), en texte.
    let heureOuverture: String?
    /// `heure_fermeture` (`time`), en texte.
    let heureFermeture: String?
    /// `horizon_jours`.
    let horizonJours: Int?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case sport
        case heureOuverture = "heure_ouverture"
        case heureFermeture = "heure_fermeture"
        case horizonJours = "horizon_jours"
    }

    /// Colonnes demandées. `club_id` est lu mais pas décodé : la requête filtre
    /// déjà sur le club.
    static let columns = "club_id, sport, heure_ouverture, heure_fermeture, horizon_jours"

    /// Conversion vers le type du domaine ; chaque valeur absente ou illisible
    /// prend la valeur de repli correspondante.
    ///
    /// - Returns: `nil` pour un sport inconnu de l'app.
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
    ///
    /// Utilisé aussi pour les heures des réservations, des blocages et des
    /// réservations du membre. Les secondes sont ignorées.
    ///
    /// - Parameter value: heure au format PostgreSQL `time`, ou `nil`.
    /// - Returns: `heures × 60 + minutes`, ou `nil` si la chaîne n'a pas au
    ///   moins deux parties numériques.
    static func minutes(from value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
