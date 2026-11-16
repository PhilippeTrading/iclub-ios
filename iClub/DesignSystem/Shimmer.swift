//
//  Shimmer.swift
//  iClub
//
//  Rôle
//    Squelettes de chargement plutôt que des spinners plein écran : la structure
//    de l'écran reste lisible pendant le chargement. `SkeletonBlock` dessine un
//    bloc gris arrondi à la place d'un contenu attendu, et le modificateur
//    `shimmering()` y fait passer un reflet lumineux en boucle.
//
//  Place dans l'application
//    Tous les écrans qui attendent une réponse de Supabase à leur premier
//    affichage (accueil, réservation, parties, activités, espace entraîneur,
//    profil, adhésion...) montrent quelques `SkeletonBlock` à la hauteur des
//    cartes à venir.
//
//  Accessibilité
//    Le reflet est coupé quand l'utilisateur a activé « Réduire les
//    animations » dans les réglages de l'iPhone : le bloc reste alors gris et
//    immobile.
//

import SwiftUI

/// Bloc de remplacement animé, calibré sur les surfaces de l'app.
struct SkeletonBlock: View {
    /// Hauteur du bloc en points (16 par défaut, une ligne de texte). La
    /// largeur suit celle du conteneur.
    var height: CGFloat = 16
    /// Rayon des coins en points (8 par défaut ; les écrans passent souvent
    /// `Radius.inner` ou `Radius.card` pour imiter une carte).
    var cornerRadius: CGFloat = 8

    /// Rectangle arrondi gris clair (texte secondaire à 14 %), traversé par le
    /// reflet.
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Brand.textSecondary.opacity(0.14))
            .frame(height: height)
            .shimmering()
    }
}

/// Modificateur de reflet, applicable à toute vue.
extension View {
    /// Fait passer un reflet lumineux de gauche à droite sur la vue, en boucle.
    /// - Parameter active: faux pour couper l'effet sans changer la hiérarchie
    ///   des vues (vrai par défaut).
    /// - Returns: la vue, avec le reflet quand il est actif et que « Réduire les
    ///   animations » est désactivé.
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

/// Modificateur qui porte l'animation du reflet.
private struct ShimmerModifier: ViewModifier {
    /// Reflet demandé par l'appelant.
    let active: Bool

    /// Réglage d'accessibilité « Réduire les animations ».
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Position du reflet : de -1 (hors champ à gauche) à 1 (hors champ à
    /// droite), animée en boucle à l'apparition.
    @State private var phase: CGFloat = -1

    /// Superpose au contenu une bande de dégradé blanc qui le traverse.
    /// - Parameter content: la vue à faire briller.
    /// - Returns: la vue d'origine telle quelle si l'effet est coupé, sinon la
    ///   vue avec le reflet animé, découpée à ses bords.
    func body(content: Content) -> some View {
        // Effet coupé (par l'appelant ou par l'accessibilité) : contenu brut.
        // `AnyView` unifie les deux branches, de types différents.
        guard active, !reduceMotion else { return AnyView(content) }

        return AnyView(
            content
                .overlay {
                    GeometryReader { proxy in
                        // Bande transparente, blanche à 45 % au milieu, large de
                        // 60 % du bloc. Son décalage vaut 1,6 fois la largeur
                        // par unité de phase : de -1 à 1, elle part de la gauche
                        // hors du bloc et finit au-delà du bord droit.
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        // Éclaircit le gris sous la bande au lieu de le couvrir.
                        .blendMode(.plusLighter)
                    }
                }
                // La bande ne déborde pas des bords du bloc.
                .clipped()
                .onAppear {
                    // Un passage de 1,4 seconde, relancé sans fin et toujours
                    // dans le même sens (pas d'aller-retour).
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        )
    }
}
