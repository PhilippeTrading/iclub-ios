//
//  SurfaceFilterBar.swift
//  iClub
//
//  Filtre par surface, partagé par l'écran des créneaux et celui du choix du
//  terrain. Les pastilles sont dérivées de `courts.surface` : aucune valeur
//  n'est écrite en dur, une surface inédite apparaît d'elle-même.
//
//  La barre ne s'affiche que si le sport a au moins deux surfaces distinctes.
//  C'est la règle plutôt qu'un test sur le tennis : aujourd'hui seul le tennis
//  est concerné, mais un club qui ajouterait un padel indoor et un padel
//  outdoor obtiendrait le filtre sans modification de l'app.
//
//  Place dans l'application
//    `BookingView` (écran des créneaux), `CourtPickerView` (choix du terrain)
//    et la création d'une partie ouverte (`OpenGameCreateFlow`). Ce sont ces
//    écrans qui décident de l'afficher (règle des deux surfaces) et qui
//    gardent la sélection ; dans le tunnel de réservation, elle est portée par
//    `AppRouter.bookingSurface` pour rester la même d'un écran à l'autre.
//
//  Le filtre est purement d'affichage : il ne relit rien en base.
//

import SwiftUI

/// Rangée défilante de pastilles « Tout », puis une pastille par surface.
struct SurfaceFilterBar: View {
    /// Surfaces proposées, déjà triées par `ClubCatalog.surfaces(for:)`
    /// (nombre de terrains décroissant, puis nom).
    let surfaces: [String]
    /// Couleur du sport, pour la pastille sélectionnée.
    let accent: Color
    /// Surface retenue ; `nil` signifie « Tout ».
    @Binding var selection: String?

    /// Rangée défilante horizontale des pastilles.
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // « Tout » en premier : retire le filtre.
                chip(title: "Tout", surface: nil)

                ForEach(surfaces, id: \.self) { surface in
                    chip(title: surface, surface: surface)
                }
            }
            // Marge alignée sur celle de l'écran : les pastilles défilent
            // jusqu'au bord sans être rognées au repos.
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Une pastille du filtre. Toucher la pastille déjà choisie ne fait rien.
    ///
    /// - Parameters:
    ///   - title: libellé affiché (« Tout » ou le nom de la surface).
    ///   - surface: valeur sélectionnée par la pastille, `nil` pour « Tout ».
    /// - Returns: le bouton de la pastille.
    private func chip(title: String, surface: String?) -> some View {
        let isSelected = selection == surface

        return Button {
            guard !isSelected else { return }
            selection = surface
            Haptics.selection()
        } label: {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Brand.textSecondary)
                // Fond plein de la couleur du sport si choisie, blanc sinon.
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Brand.surface)
                }
                // Filet fin autour des pastilles non choisies.
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? .clear : Brand.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Aperçu Xcode avec trois surfaces de tennis.
#Preview {
    // Surface choisie dans l'aperçu ; « Tout » au départ.
    @Previewable @State var selection: String?

    return SurfaceFilterBar(
        surfaces: ["Terre battue", "Béton poreux", "Terre battue artificielle"],
        accent: Sport.tennis.accent,
        selection: $selection
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.background)
}
