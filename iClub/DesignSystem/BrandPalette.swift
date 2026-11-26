//
//  BrandPalette.swift
//  iClub
//
//  Jetons de couleur repris du web pour garder une cohérence visuelle avec le
//  site et les emails. Chaque jeton existe en variante claire et sombre dans
//  l'asset catalog : les tons de fond s'assombrissent, les tons de texte et
//  d'accent s'éclaircissent pour conserver le contraste (convention Apple).
//
//  Conséquence à respecter : un aplat plein bleu marine (`navy700`) ou de la
//  couleur du texte principal devient très clair en mode sombre. Le texte posé
//  sur un tel aplat prend `textOnInverse`, jamais un blanc fixe, qui y
//  disparaîtrait (fiche D13, 26 novembre 2026).
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

    /// Fond de page : blanc. Le crème `neutral50` d'origine reste dans le
    /// catalogue de couleurs si l'on veut y revenir.
    static let background = Color(.neutral0)
    /// Fond de carte posée sur le fond de page.
    static let surface = Color(.neutral0)
    /// Texte principal.
    static let textPrimary = Color(.neutral900)
    /// Texte secondaire et métadonnées.
    static let textSecondary = Color(.neutral500)
    /// Texte et pictogrammes posés sur un aplat plein bleu marine (`navy700`)
    /// ou de la couleur du texte principal : pastille sélectionnée, jour
    /// choisi, séparateur de jour, bouton d'envoi, compteur.
    ///
    /// Blanc en mode clair, exactement le blanc employé jusque-là : rien ne
    /// change à l'écran. En mode sombre, ces aplats deviennent très clairs ; on
    /// y pose la couleur sombre du fond de page, qui garde un fort contraste.
    /// C'est le même jeton que `background` (`neutral0`), nommé pour son usage.
    ///
    /// Les aplats d'accent sport (terre battue, pin, pickleball) ne sont pas
    /// concernés : plus soutenus en mode sombre, ils gardent leur texte blanc,
    /// que le propriétaire n'a pas demandé de changer (fiche D13).
    static let textOnInverse = Color(.neutral0)

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
