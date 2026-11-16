//
//  AuroraBackground.swift
//  iClub
//
//  Rôle
//    Fond en dégradé maillé sur lequel le matériau Liquid Glass prend tout son
//    sens : les panneaux en verre laissent transparaître la couleur derrière eux.
//
//  Place dans l'application
//    Écrans d'avant connexion et d'attente : connexion (SignInView), création
//    de compte (SignUpView), complément de profil (ProfileCompletionView),
//    écran de lancement (LaunchView) et écran « Compte en attente »
//    (BlockedView) de RootView.swift ; l'aperçu Xcode de BrandMark s'en sert
//    aussi. Les écrans de l'app connectée, eux, posent leurs cartes sur le fond
//    uni `Brand.background`.
//
//  Couleurs
//    Les teintes sont celles de la palette (`Brand`, BrandPalette.swift) : en
//    clair, les fonds pâles terre battue et vert sapin (clay50, pine50) et leurs
//    mélanges avec les tons soutenus ; en sombre, le fond sombre mélangé à la
//    terre battue, au vert sapin et au bleu marine. Rien n'est écrit en dur.
//
//  Le dégradé est **figé et centré**, volontairement. Il dérivait auparavant
//  d'un bord à l'autre en boucle, ce qui donnait une impression de cadre qui
//  glisse derrière le contenu, bords visibles compris, sur un écran où l'on ne
//  fait que saisir ses identifiants. Un fond immobile n'a besoin d'aucune
//  précaution : ni portée d'animation, ni « Réduire les animations » à respecter.
//

import SwiftUI

/// Fond coloré et immobile des écrans d'authentification, en dégradé maillé
/// 3 × 3 qui suit l'apparence claire ou sombre.
struct AuroraBackground: View {
    /// Apparence courante (claire ou sombre), qui choisit la palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Les neuf couleurs de la maille, ligne par ligne, de haut en bas.
    ///
    /// Les teintes sont construites par mélange plutôt qu'en opacité : un
    /// `MeshGradient` interpole des couleurs opaques, un alpha y produirait des
    /// zones délavées. Le fond doit rester doux mais *coloré*, sinon le verre
    /// n'a rien à réfracter et la profondeur disparaît.
    private var palette: [Color] {
        // Sombre : coins au fond sombre, centre en terre battue, côtés en vert
        // sapin et bleu marine. Les proportions de mélange (38 %, 42 %, 30 %)
        // gardent des teintes sourdes, assez colorées pour le verre.
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
            // Clair : fonds pâles terre battue et vert sapin, avec deux
            // versions un peu plus soutenues (22 % et 20 % du ton 800) pour le
            // centre et le côté gauche.
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
    /// Coordonnées relatives, de 0 (bord gauche ou haut) à 1 (bord droit ou bas).
    private let points: [SIMD2<Float>] = [
        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
    ]

    /// Le dégradé, son voile de barre d'état, étendu à tout l'écran.
    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: palette)
            .overlay(alignment: .top) { statusBarVeil }
            // Occupe toute la proposition reçue, sans dépendre d'une taille
            // intrinsèque que `MeshGradient` n'a pas. Cela vaut aussi quand il
            // est posé en `.background` d'un `ScrollView`, dont la taille est
            // résolue dans une passe de mise en page ultérieure.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Passe sous la barre d'état et l'indicateur d'accueil.
            .ignoresSafeArea()
    }

    /// Voile très léger pour garantir la lisibilité de la barre d'état : le fond
    /// de page à 35 % d'opacité en haut, qui s'efface jusqu'à 22 % de la
    /// hauteur de l'écran.
    private var statusBarVeil: some View {
        LinearGradient(
            colors: [Brand.background.opacity(0.35), .clear],
            startPoint: .top,
            endPoint: .init(x: 0.5, y: 0.22)
        )
    }
}

/// Aperçu Xcode du fond seul.
#Preview {
    AuroraBackground()
}
