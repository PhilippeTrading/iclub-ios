//
//  Typography.swift
//  iClub
//
//  Rôle
//    Styles de texte partagés : `Font.editorial` pour les titres, `Font.numeral`
//    pour les chiffres mis en avant, `metaLabelStyle()` pour les petites
//    étiquettes en capitales.
//
//  Choix des polices
//    SF Pro (la police système d'iOS) pour le corps de texte, SF Pro Rounded
//    (sa variante arrondie, `design: .rounded`) pour les titres éditoriaux et
//    les gros chiffres (crédits invités, classements) : plus convivial, plus
//    club. L'app n'embarque aucune police : le web utilise Manrope pour
//    l'interface et Cormorant Garamond pour les titres
//    (`src/app/layout.tsx` du dépôt iclub-web), l'app s'en tient aux polices
//    d'Apple, sans fichier de police à livrer ni à licencier.
//
//  Accessibilité
//    Les styles de ce fichier passent tous par des `Font.TextStyle` (`.title3`,
//    `.headline`, `.caption2`, etc.) plutôt que par des tailles fixes : le
//    texte suit la taille choisie par l'utilisateur dans les réglages de
//    l'iPhone (Dynamic Type). Ailleurs dans l'app, des icônes et quelques
//    petits textes (pastille de non-lus, par exemple) gardent une taille fixe
//    en points (`.system(size:)`), qui ne suit pas ce réglage.
//

import SwiftUI

/// Polices nommées de l'app, à utiliser avec `.font(...)`.
extension Font {

    /// Titre éditorial arrondi, calé sur un style système donc redimensionnable.
    ///
    /// Sert aux titres d'écran, de carte et de section dans toute l'app.
    /// - Parameters:
    ///   - style: style de texte système dont la taille est reprise (et suit
    ///     Dynamic Type), par exemple `.title3` ou `.headline`.
    ///   - weight: graisse, gras par défaut.
    /// - Returns: la police SF Pro Rounded à ce style et cette graisse.
    static func editorial(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// Chiffre mis en avant (solde de crédits, classement).
    ///
    /// Même dessin arrondi qu'`editorial`, mais en demi-gras par défaut.
    /// - Parameters:
    ///   - style: style de texte système dont la taille est reprise.
    ///   - weight: graisse, demi-gras par défaut.
    /// - Returns: la police SF Pro Rounded à ce style et cette graisse.
    static func numeral(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// Style de texte composé (police, casse, espacement, couleur), applicable à
/// toute vue de texte.
extension View {

    /// Petite étiquette de métadonnée : capitales discrètes, légèrement espacées.
    ///
    /// Utilisée pour les intitulés de section et les libellés posés au-dessus
    /// d'une valeur (« Format », « Niveau recherché », date d'une partie...).
    /// Le texte est passé en capitales à l'affichage seulement (`textCase`) :
    /// la chaîne d'origine n'est pas modifiée.
    /// - Returns: la vue avec la police, la casse, l'espacement des lettres
    ///   (0,8 point) et la couleur de texte secondaire.
    func metaLabelStyle() -> some View {
        self
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Brand.textSecondary)
    }
}
