//
//  BrandPalette.swift
//  iClub
//
//  Jetons de couleur repris du web pour garder une cohérence visuelle avec le
//  site et les emails. Chaque jeton existe en variante claire et sombre dans
//  l'asset catalog : les tons de fond s'assombrissent, les tons de texte et
//  d'accent s'éclaircissent pour conserver le contraste (convention Apple).
//

import SwiftUI

enum Brand {

    // MARK: - Accents sport

    static let clay800 = Color(.clay800)
    static let clay50 = Color(.clay50)
    static let pine800 = Color(.pine800)
    static let pine50 = Color(.pine50)
    static let pickle800 = Color(.pickle800)
    static let pickle50 = Color(.pickle50)

    // MARK: - Marque

    static let navy800 = Color(.navy800)
    static let navy700 = Color(.navy700)

    // MARK: - Neutres

    /// Fond de page.
    static let background = Color(.neutral50)
    /// Fond de carte posée sur le fond de page.
    static let surface = Color(.neutral0)
    /// Texte principal.
    static let textPrimary = Color(.neutral900)
    /// Texte secondaire et métadonnées.
    static let textSecondary = Color(.neutral500)

    // MARK: - États

    static let success = Color(.success600)
    static let warning = Color(.warning600)
    static let error = Color(.error600)

    // MARK: - Traits

    /// Filet très discret qui détache une carte de son fond sans ombre lourde.
    static let hairline = Color(.neutral500).opacity(0.18)
}

// MARK: - Rayons

/// Rayons concentriques : les conteneurs imbriqués décroissent régulièrement
/// pour conserver des coins continus alignés (pas d'angle dur nulle part).
enum Radius {
    static let card: CGFloat = 26
    static let inner: CGFloat = 18
    static let chip: CGFloat = 14
    static let control: CGFloat = 20
}

extension RoundedRectangle {
    /// Squircle : coins continus, jamais de coin circulaire.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
