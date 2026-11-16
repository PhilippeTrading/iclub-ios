//
//  SportShortcutTile.swift
//  iClub
//
//  Raccourci « Réserver {sport} » de l'accueil. Le nombre de terrains vient de
//  la requête `courts`, jamais d'une constante.
//
//  Place dans l'application
//    Tuiles de l'accueil (`HomeView`), une pour le tennis et une pour le padel
//    quand ils ont au moins un terrain réservable. Le tap ouvre l'onglet
//    « Réserver » sur le sport choisi (`AppRouter.openBooking(for:)`, décidé
//    par l'accueil).
//
//  Ce fichier déclare aussi le style de bouton `.tile` (léger recul à
//  l'appui), utilisé par ces tuiles.
//

import SwiftUI

/// Tuile cliquable « Réserver Tennis, 6 terrains », aux couleurs du sport.
struct SportShortcutTile: View {
    /// Sport proposé : fixe l'icône, la couleur et le libellé.
    let sport: Sport
    /// Nombre de terrains réservables du sport, calculé par `ClubCatalog`
    /// (terrains actifs, hors terrains fermés à la personne).
    let courtCount: Int
    /// Action du tap, fournie par l'accueil.
    let action: () -> Void

    /// La tuile entière est un bouton, au style `.tile`.
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                // Pictogramme du sport dans une pastille teintée.
                Image(systemName: sport.symbolName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(sport.accent)
                    .frame(width: 44, height: 44)
                    .background(sport.accent.opacity(0.14), in: .circle)

                // « Réserver », nom du sport, nombre de terrains accordé.
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
            // Filet de la couleur du sport autour de la tuile.
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(sport.accent.opacity(0.14), lineWidth: 0.5)
            }
            // Toute la surface arrondie est sensible au tap.
            .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.tile)
        .accessibilityLabel(
            "Réserver \(sport.displayName), \(courtCount) \(courtCount > 1 ? "terrains" : "terrain")"
        )
    }
}

/// Style de bouton pour les cartes : léger recul à l'appui, ressort physique.
/// La carte se réduit à 96 % pendant l'appui puis revient avec un ressort.
struct TileButtonStyle: ButtonStyle {
    /// Applique l'effet d'appui au contenu du bouton.
    ///
    /// - Parameter configuration: contenu du bouton et état d'appui.
    /// - Returns: le contenu, réduit pendant l'appui.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Raccourci d'écriture : `.buttonStyle(.tile)`.
extension ButtonStyle where Self == TileButtonStyle {
    /// Le style de tuile, voir `TileButtonStyle`.
    static var tile: TileButtonStyle { TileButtonStyle() }
}

/// Aperçu Xcode des deux tuiles côte à côte.
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
