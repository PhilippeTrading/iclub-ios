//
//  Surfaces.swift
//  iClub
//
//  Deux familles de surfaces, conformément à la direction artistique :
//
//  • `glassPanel` — matériau Liquid Glass, réservé aux éléments *flottants*
//    (panneaux d'authentification posés sur le dégradé, résumés en overlay,
//    feuilles modales, boutons d'action). Le verre n'a de sens que s'il laisse
//    deviner quelque chose derrière lui.
//  • `surfaceCard` — carte opaque posée sur le fond de page, pour le contenu
//    de liste. Profondeur donnée par un filet clair + une ombre très douce,
//    jamais par une ombre portée épaisse.
//

import SwiftUI

extension View {

    /// Panneau en Liquid Glass. À placer dans un `GlassEffectContainer` lorsqu'il
    /// cohabite avec d'autres éléments en verre susceptibles de fusionner.
    func glassPanel(cornerRadius: CGFloat = Radius.card) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Carte de contenu opaque.
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
struct SurfaceCard<Content: View>: View {
    var cornerRadius: CGFloat = Radius.card
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: cornerRadius)
    }
}

/// Pastille de métadonnée (sport, mixité, ambiance…).
struct BrandChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = Brand.navy700
    var background: Color?

    var body: some View {
        HStack(spacing: 5) {
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
