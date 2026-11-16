//
//  BrandPalette.swift
//  iClub
//
//  Rôle
//    Jetons de couleur de l'app (enum `Brand`), rayons d'arrondi (enum `Radius`)
//    et forme « squircle » des cartes. Les vues lisent leurs couleurs ici plutôt
//    que d'écrire une valeur en dur : modifier un jeton recolore l'app entière.
//
//  D'où viennent les couleurs
//    Chaque jeton pointe vers un jeu de couleurs (colorset) du catalogue
//    `iClub/Assets.xcassets` : `Clay800.colorset`, `Pine50.colorset`, etc.
//    Le réglage Xcode ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS
//    (activé dans le projet) produit pour chaque colorset un symbole
//    `ColorResource` à son nom (Clay800 devient `.clay800`), d'où l'écriture
//    `Color(.clay800)` : un nom mal orthographié est une erreur de compilation,
//    jamais une couleur absente à l'exécution.
//
//    Les valeurs claires reprennent à l'identique la charte du web, c'est-à-dire
//    les variables `--color-*` du thème « iclub » par défaut
//    (`src/app/globals.css` du dépôt iclub-web) : navy-800 #14253B,
//    navy-700 #1D3350, clay-800 #9C4F32, clay-50 #F6ECE7, pine-800 #24473B,
//    pine-50 #EDF3EF, neutral-0 #FFFFFF, neutral-50 #F7F4EE,
//    neutral-500 #6B747C, neutral-900 #1C2329, success-600 #2F6B4F,
//    warning-600 #A46A1F, error-600 #B54747. L'app, le site et les courriels
//    gardent ainsi la même identité visuelle. Comme sur le web, la terre battue
//    (« clay ») colore le tennis et le vert sapin (« pine ») le padel.
//    La gamme « pickle » (pickleball : ocre #A8762B, fond #F7EFE1) n'existe pas
//    dans la charte du web : elle est propre à l'app.
//
//    Le catalogue contient aussi `AccentColor`, de mêmes valeurs que Navy700,
//    déclarée comme couleur d'accent globale du projet
//    (ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME) : c'est la teinte par
//    défaut des contrôles système. `Neutral50`, le crème d'origine du fond de
//    page, y reste sans être lu par aucun code (voir `background`).
//
//  Mode sombre
//    Chaque colorset porte une seconde valeur pour l'apparence sombre, et iOS
//    passe seul de l'une à l'autre quand l'utilisateur change d'apparence. Ces
//    valeurs sombres sont propres à l'app (elles ne reprennent pas le thème
//    sombre « Nuit » du web) : les tons de fond (gammes 50, neutral-0)
//    s'assombrissent, les tons de texte et d'accent (700, 800, 900, couleurs
//    d'état) s'éclaircissent pour garder le contraste, selon la convention
//    d'Apple. Par exemple Navy800 vaut #14253B en clair et #DCE6F2 en sombre.
//
//  Points d'attention
//    - Limite connue : l'app ne suit pas le thème de couleurs qu'un club peut
//      choisir sur le web (`src/app/themes.css` : Terre battue, Padel, Bassin,
//      Ardoise, Bordeaux, Nuit) ; elle garde partout la palette iClub d'origine.
//    - Renommer un colorset change le nom du symbole généré et casse la
//      compilation de ce fichier : c'est le garde-fou voulu.
//    - Les jetons sont des constantes statiques : aucune vue ne doit les
//      recalculer, ils suivent d'eux-mêmes l'apparence claire ou sombre.
//

import SwiftUI

/// Palette de l'app : un jeton nommé par rôle (accent de sport, marque, fond,
/// texte, état, filet). Les valeurs viennent du catalogue `Assets.xcassets`
/// (voir l'en-tête du fichier) et existent chacune en clair et en sombre.
enum Brand {

    // MARK: - Accents sport

    /// Terre battue soutenue (#9C4F32 en clair) : accent du tennis
    /// (`Sport.accent`), icônes et textes mis en couleur.
    static let clay800 = Color(.clay800)
    /// Terre battue très pâle (#F6ECE7 en clair) : fond teinté des tuiles et
    /// pastilles du tennis (`Sport.tintedBackground`), et teinte du dégradé
    /// d'accueil (`AuroraBackground`).
    static let clay50 = Color(.clay50)
    /// Vert sapin soutenu (#24473B en clair) : accent du padel.
    static let pine800 = Color(.pine800)
    /// Vert sapin très pâle (#EDF3EF en clair) : fond teinté du padel, et
    /// seconde teinte du dégradé d'accueil.
    static let pine50 = Color(.pine50)
    /// Ocre soutenu (#A8762B en clair) : accent du pickleball, propre à l'app.
    static let pickle800 = Color(.pickle800)
    /// Ocre très pâle (#F7EFE1 en clair) : fond teinté du pickleball.
    static let pickle50 = Color(.pickle50)

    // MARK: - Marque

    /// Bleu marine le plus soutenu (#14253B en clair, navy-800 du web) : encre
    /// des titres et des icônes mis en avant (logo, écrans de confirmation,
    /// en-têtes de section).
    static let navy800 = Color(.navy800)
    /// Bleu marine principal (#1D3350 en clair, navy-700 du web) : teinte
    /// d'accent de l'app (barre d'onglets, bouton principal, messages
    /// d'information).
    static let navy700 = Color(.navy700)

    // MARK: - Neutres

    /// Fond de page : blanc (#FFFFFF en clair, #1C1E22 en sombre). Le crème
    /// `neutral50` d'origine reste dans le catalogue de couleurs si l'on veut
    /// y revenir.
    static let background = Color(.neutral0)
    /// Fond de carte posée sur le fond de page. Même couleur que le fond : la
    /// carte s'en détache par son filet (`hairline`) et une ombre douce (voir
    /// `surfaceCard()` dans Surfaces.swift).
    static let surface = Color(.neutral0)
    /// Texte principal (#1C2329 en clair, presque blanc en sombre).
    static let textPrimary = Color(.neutral900)
    /// Texte secondaire et métadonnées (#6B747C en clair).
    static let textSecondary = Color(.neutral500)

    // MARK: - États

    /// Succès, confirmation, élément acquis (#2F6B4F en clair).
    static let success = Color(.success600)
    /// Avertissement, élément en attente ou à surveiller (#A46A1F en clair).
    static let warning = Color(.warning600)
    /// Erreur, action destructrice, pastille de non-lus (#B54747 en clair).
    static let error = Color(.error600)

    // MARK: - Traits

    /// Filet très discret qui détache une carte de son fond sans ombre lourde :
    /// le gris secondaire à 18 % d'opacité.
    static let hairline = Color(.neutral500).opacity(0.18)
}

// MARK: - Rayons

/// Rayons concentriques : les conteneurs imbriqués décroissent régulièrement
/// pour conserver des coins continus alignés (pas d'angle dur nulle part).
/// Valeurs en points.
enum Radius {
    /// Carte de contenu et panneau de verre (`surfaceCard`, `glassPanel`).
    static let card: CGFloat = 26
    /// Carte plus petite ou bloc imbriqué (ligne de créneau, choix du
    /// terrain, squelette de chargement).
    static let inner: CGFloat = 18
    /// Pastille (`BrandChip`), message en ligne (`InlineMessage`), case de la
    /// bande des jours.
    static let chip: CGFloat = 14
    /// Groupe de champs de formulaire (`GlassFieldGroup`).
    static let control: CGFloat = 20
}

/// Raccourci de forme pour les fonds et contours à coins continus.
extension RoundedRectangle {
    /// Squircle : coins continus, jamais de coin circulaire.
    ///
    /// Le style `.continuous` adoucit la jonction entre le côté droit et
    /// l'arrondi, comme les icônes et les fenêtres d'iOS.
    /// - Parameter radius: rayon de l'arrondi en points, en général une valeur
    ///   de `Radius`.
    /// - Returns: le rectangle arrondi, à utiliser comme forme de fond, de
    ///   contour ou de découpe.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
