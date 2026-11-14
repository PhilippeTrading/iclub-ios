//
//  GameFormat.swift
//  iClub
//
//  Format de jeu, qui détermine la capacité de la partie.
//
//  Le padel se joue toujours en double : ce n'est pas un choix, c'est une
//  information. Tennis et pickleball laissent le choix, simple par défaut.
//
//  Place dans l'application
//    Écrit dans `reservations.format` (valeurs `simple` ou `double`, contrainte
//    `check` de la colonne) par la réservation d'un terrain et la création d'une
//    partie ouverte ; relu par `MyReservation` pour savoir si une partie ouverte
//    est complète. La base applique la même capacité (2 ou 4) dans
//    `join_open_game`.
//

import Foundation

/// Simple ou double.
nonisolated enum GameFormat: String, CaseIterable, Sendable {
    /// Deux joueurs.
    case simple
    /// Quatre joueurs.
    case double

    /// Nombre de participants attendus.
    var capacity: Int {
        switch self {
        case .simple: 2
        case .double: 4
        }
    }

    /// Libellé affiché (« Simple », « Double »).
    var displayName: String {
        switch self {
        case .simple: "Simple"
        case .double: "Double"
        }
    }

    /// Sous-titre du choix : « 2 joueurs » ou « 4 joueurs ».
    var detail: String { "\(capacity) joueurs" }

    /// Formats proposés pour un sport. Un seul élément = aucun choix à faire.
    ///
    /// - Parameter sport: sport de la réservation.
    /// - Returns: double seul pour le padel, simple et double sinon.
    static func options(for sport: Sport) -> [GameFormat] {
        sport == .padel ? [.double] : [.simple, .double]
    }

    /// Format présélectionné.
    ///
    /// - Parameter sport: sport de la réservation.
    /// - Returns: double pour le padel, simple pour les autres sports.
    static func preferred(for sport: Sport) -> GameFormat {
        sport == .padel ? .double : .simple
    }
}
