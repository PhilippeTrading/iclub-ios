//
//  Sport.swift
//  iClub
//

import SwiftUI

/// Valeurs alignées sur la colonne `courts.sport` côté Supabase.
enum Sport: String, CaseIterable, Codable, Identifiable, Sendable {
    case tennis
    case padel
    case pickleball

    var id: String { rawValue }

    /// `nonisolated` : du texte pur, utilisé par les moteurs de règles qui
    /// tournent hors de l'acteur principal (admission à une partie ouverte).
    nonisolated var displayName: String {
        switch self {
        case .tennis: "Tennis"
        case .padel: "Padel"
        case .pickleball: "Pickleball"
        }
    }

    /// SF Symbols n'a pas de glyphe padel : `figure.racquetball` en est le plus
    /// proche (court fermé, raquette courte).
    var symbolName: String {
        switch self {
        case .tennis: "figure.tennis"
        case .padel: "figure.racquetball"
        case .pickleball: "figure.pickleball"
        }
    }

    /// Accent principal du sport.
    var accent: Color {
        switch self {
        case .tennis: Brand.clay800
        case .padel: Brand.pine800
        case .pickleball: Brand.pickle800
        }
    }

    /// Fond tinté associé, pour les tuiles et les pastilles.
    var tintedBackground: Color {
        switch self {
        case .tennis: Brand.clay50
        case .padel: Brand.pine50
        case .pickleball: Brand.pickle50
        }
    }
}

// La durée d'un créneau n'est délibérément pas une propriété du sport : elle est
// portée par chaque terrain (`courts.duree_creneau_minutes`) et modifiable par
// l'admin depuis le back-office web.
