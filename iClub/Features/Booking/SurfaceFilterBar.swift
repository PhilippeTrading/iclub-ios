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

import SwiftUI

struct SurfaceFilterBar: View {
    let surfaces: [String]
    let accent: Color
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(title: "Tout", surface: nil)

                ForEach(surfaces, id: \.self) { surface in
                    chip(title: surface, surface: surface)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

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
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Brand.surface)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? .clear : Brand.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    @Previewable @State var selection: String?

    return SurfaceFilterBar(
        surfaces: ["Terre battue", "Béton poreux", "Terre battue artificielle"],
        accent: Sport.tennis.accent,
        selection: $selection
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.background)
}
