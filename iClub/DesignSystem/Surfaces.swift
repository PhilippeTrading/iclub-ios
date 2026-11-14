//
//  Surfaces.swift
//  iClub
//
//  Rôle
//    Les surfaces sur lesquelles se pose le contenu, et la pastille de
//    métadonnée. Deux familles de surfaces, conformément à la direction
//    artistique :
//
//  • `glassPanel` : matériau Liquid Glass, réservé aux éléments *flottants*
//    (panneaux d'authentification posés sur le dégradé, résumés en overlay,
//    feuilles modales, boutons d'action). Le verre n'a de sens que s'il laisse
//    deviner quelque chose derrière lui.
//  • `surfaceCard` : carte opaque posée sur le fond de page, pour le contenu
//    de liste. Profondeur donnée par un filet clair et une ombre très douce,
//    jamais par une ombre portée épaisse.
//
//  Place dans l'application
//    `glassPanel` n'est appelé directement que par `GlassFieldGroup`
//    (FormControls.swift) ; les autres éléments en verre de l'app (boutons,
//    bulle de messagerie, logo) posent `.glassEffect` eux-mêmes. `surfaceCard`
//    et `SurfaceCard` portent presque toutes les cartes des écrans connectés,
//    `BrandChip` toutes les pastilles (sport, statut, niveau...).
//
//  Points d'attention
//    Le matériau Liquid Glass (`glassEffect`) demande iOS 26 ou plus récent ;
//    le projet vise iOS 27 (IPHONEOS_DEPLOYMENT_TARGET), il est donc toujours
//    disponible.
//

import SwiftUI

/// Les deux surfaces de l'app, en modificateurs applicables à toute vue.
extension View {

    /// Panneau en Liquid Glass. À placer dans un `GlassEffectContainer` lorsqu'il
    /// cohabite avec d'autres éléments en verre susceptibles de fusionner.
    /// - Parameter cornerRadius: rayon des coins continus, en points
    ///   (`Radius.card` par défaut).
    /// - Returns: la vue sur un fond de verre standard (`.regular`) à sa forme.
    func glassPanel(cornerRadius: CGFloat = Radius.card) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Carte de contenu opaque.
    ///
    /// Trois couches : le fond `Brand.surface` à coins continus, un filet de
    /// 0,5 point (`Brand.hairline`) tracé à l'intérieur du bord, et une ombre
    /// noire à 5 % d'opacité, floue de 12 points et décalée de 4 points vers le
    /// bas.
    /// - Parameter cornerRadius: rayon des coins, en points (`Radius.card` par
    ///   défaut).
    /// - Returns: la vue posée sur sa carte. Les marges intérieures restent à
    ///   la charge de l'appelant (ou de `SurfaceCard`).
    func surfaceCard(cornerRadius: CGFloat = Radius.card) -> some View {
        self
            .background(Brand.surface, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 4)
    }
}

/// Carte de contenu standard : padding cohérent + surface opaque.
///
/// Le contenu est aligné à gauche et la carte prend toute la largeur
/// disponible, ce qui aligne les cartes empilées d'un écran.
struct SurfaceCard<Content: View>: View {
    /// Rayon des coins, en points (`Radius.card` par défaut).
    var cornerRadius: CGFloat = Radius.card
    /// Marge intérieure sur les quatre côtés, en points (18 par défaut).
    var padding: CGFloat = 18
    /// Contenu de la carte, construit par l'appelant.
    @ViewBuilder var content: Content

    /// Le contenu, sa marge, sa pleine largeur, puis la carte opaque.
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: cornerRadius)
    }
}

/// Pastille de métadonnée (sport, mixité, ambiance…).
///
/// Texte en police arrondie, icône facultative devant, sur un fond teinté à
/// coins continus (`Radius.chip`).
struct BrandChip: View {
    /// Texte de la pastille.
    let title: String
    /// Symbole SF Symbols facultatif placé devant le texte ; `nil` : pas
    /// d'icône.
    var systemImage: String?
    /// Couleur du texte et de l'icône (bleu marine par défaut).
    var tint: Color = Brand.navy700
    /// Fond de la pastille ; `nil` : la teinte à 12 % d'opacité.
    var background: Color?

    /// Icône éventuelle et texte côte à côte, sur le fond teinté.
    var body: some View {
        HStack(spacing: 5) {
            // Icône seulement si l'appelant en a fourni une.
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            background ?? tint.opacity(0.12),
            in: .rect(cornerRadius: Radius.chip, style: .continuous)
        )
    }
}
