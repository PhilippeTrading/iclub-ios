//
//  GameFormat.swift
//  iClub
//
//  Format de jeu, qui détermine la capacité de la partie.
//
//  Le padel se joue toujours en double : ce n'est pas un choix, c'est une
//  information. Tennis et pickleball laissent le choix, simple par défaut.
//

import Foundation

nonisolated enum GameFormat: String, CaseIterable, Sendable {
    case simple
    case double

    /// Nombre de participants attendus.
    var capacity: Int {
        switch self {
        case .simple: 2
        case .double: 4
        }
    }

    var displayName: String {
        switch self {
        case .simple: "Simple"
        case .double: "Double"
        }
    }

    var detail: String { "\(capacity) joueurs" }

    /// Formats proposés pour un sport. Un seul élément = aucun choix à faire.
    static func options(for sport: Sport) -> [GameFormat] {
        sport == .padel ? [.double] : [.simple, .double]
    }

    static func preferred(for sport: Sport) -> GameFormat {
        sport == .padel ? .double : .simple
    }
}
