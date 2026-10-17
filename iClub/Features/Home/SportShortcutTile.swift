//
//  SportShortcutTile.swift
//  iClub
//
//  Raccourci « Réserver {sport} » de l'accueil. Le nombre de terrains vient de
//  la requête `courts`, jamais d'une constante.
//

import SwiftUI

struct SportShortcutTile: View {
    let sport: Sport
    let courtCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: sport.symbolName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(sport.accent)
                    .frame(width: 44, height: 44)
                    .background(sport.accent.opacity(0.14), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Réserver")
                        .metaLabelStyle()

                    Text(sport.displayName)
                        .font(.editorial(.title3))
                        .foregroundStyle(Brand.textPrimary)

                    Text(courtCount > 1 ? "\(courtCount) terrains" : "\(courtCount) terrain")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                sport.tintedBackground,
                in: .rect(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(sport.accent.opacity(0.14), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.tile)
        .accessibilityLabel(
            "Réserver \(sport.displayName), \(courtCount) \(courtCount > 1 ? "terrains" : "terrain")"
        )
    }
}

/// Style de bouton pour les cartes : léger recul à l'appui, ressort physique.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TileButtonStyle {
    static var tile: TileButtonStyle { TileButtonStyle() }
}

#Preview {
    ZStack {
        Brand.background.ignoresSafeArea()
        HStack(spacing: 12) {
            SportShortcutTile(sport: .tennis, courtCount: 6) {}
            SportShortcutTile(sport: .padel, courtCount: 3) {}
        }
        .padding()
    }
}
