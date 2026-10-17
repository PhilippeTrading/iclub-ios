//
//  Typography.swift
//  iClub
//
//  SF Pro pour le corps de texte, SF Pro Rounded pour les titres éditoriaux et
//  les gros chiffres (crédits invités, classements) : plus convivial, plus club.
//  Tout passe par des `Font.TextStyle` pour rester compatible Dynamic Type.
//

import SwiftUI

extension Font {

    /// Titre éditorial arrondi, calé sur un style système donc redimensionnable.
    static func editorial(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// Chiffre mis en avant (solde de crédits, classement).
    static func numeral(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension View {

    /// Petite étiquette de métadonnée : capitales discrètes, légèrement espacées.
    func metaLabelStyle() -> some View {
        self
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Brand.textSecondary)
    }
}
