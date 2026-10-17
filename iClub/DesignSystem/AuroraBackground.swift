//
//  AuroraBackground.swift
//  iClub
//
//  Fond en dégradé maillé sur lequel le matériau Liquid Glass prend tout son
//  sens : les panneaux en verre laissent transparaître la couleur derrière eux.
//
//  Le dégradé est **figé et centré**, volontairement. Il dérivait auparavant
//  d'un bord à l'autre en boucle, ce qui donnait une impression de cadre qui
//  glisse derrière le contenu, bords visibles compris, sur un écran où l'on ne
//  fait que saisir ses identifiants. Un fond immobile n'a besoin d'aucune
//  précaution : ni portée d'animation, ni « Réduire les animations » à respecter.
//

import SwiftUI

struct AuroraBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Les teintes sont construites par mélange plutôt qu'en opacité : un
    /// `MeshGradient` interpole des couleurs opaques, un alpha y produirait des
    /// zones délavées. Le fond doit rester doux mais *coloré*, sinon le verre
    /// n'a rien à réfracter et la profondeur disparaît.
    private var palette: [Color] {
        if colorScheme == .dark {
            let clay = Brand.background.mix(with: Brand.clay800, by: 0.38)
            let pine = Brand.background.mix(with: Brand.pine800, by: 0.42)
            let navy = Brand.background.mix(with: Brand.navy700, by: 0.30)
            return [
                Brand.background, navy, Brand.background,
                pine, clay, navy,
                Brand.background, pine, Brand.background,
            ]
        } else {
            let clayLight = Brand.clay50
            let clayDeep = Brand.clay50.mix(with: Brand.clay800, by: 0.22)
            let pineLight = Brand.pine50
            let pineDeep = Brand.pine50.mix(with: Brand.pine800, by: 0.20)
            return [
                Brand.background, clayLight, Brand.background,
                pineDeep, clayDeep, pineLight,
                Brand.background, pineLight, clayLight,
            ]
        }
    }

    /// Maille régulière 3 × 3, point central à l'exact milieu de l'écran : la
    /// teinte chaude du centre de la palette y reste posée, sans décentrage.
    private let points: [SIMD2<Float>] = [
        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
    ]

    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: palette)
            .overlay(alignment: .top) { statusBarVeil }
            // Occupe toute la proposition reçue, sans dépendre d'une taille
            // intrinsèque que `MeshGradient` n'a pas — y compris posé en
            // `.background` d'un `ScrollView`, dont la taille est résolue dans
            // une passe de mise en page ultérieure.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    /// Voile très léger pour garantir la lisibilité de la barre d'état.
    private var statusBarVeil: some View {
        LinearGradient(
            colors: [Brand.background.opacity(0.35), .clear],
            startPoint: .top,
            endPoint: .init(x: 0.5, y: 0.22)
        )
    }
}

#Preview {
    AuroraBackground()
}
