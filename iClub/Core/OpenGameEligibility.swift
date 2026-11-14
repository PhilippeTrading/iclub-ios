//
//  OpenGameEligibility.swift
//  iClub
//
//  Peut-on rejoindre cette partie ?
//
//  Les règles sont **strictes** : il n'existe aucun « rejoindre quand même ».
//  La fonction `join_open_game` refait tous ces contrôles côté base, sous
//  verrou de ligne. Ce moteur ne sert donc pas à protéger la base, mais à
//  expliquer le refus *avant* d'envoyer une requête vouée à l'échec.
//
//  Fonction pure, sans réseau : les libellés se vérifient un à un.
//
//  Place dans l'application
//    - Rejoindre : `OpenGamesView` appelle `refusal(joining:…)` avant
//      d'appeler `join_open_game`, et affiche le refus dans une fenêtre.
//    - Ouvrir une partie : `OpenGameFormView` appelle `creationBlock(…)` avant
//      toute saisie, et `allowedMixities(for:)` pour les choix de mixité.
//
//  Règles métier (mêmes que la base)
//    - Une seule partie ouverte par jour et par membre, tous sports confondus
//      (déclencheur `one_open_game_per_day` sur `reservation_participants`).
//    - Mixité : une partie « hommes » ou « femmes » exige un sexe renseigné et
//      conforme.
//    - Niveau : le classement du membre doit tomber dans la fourchette de la
//      partie, comparée par position sur l'échelle (`Ranking`, même échelle que
//      la fonction SQL `level_index`).
//
//  Points d'attention
//    - Ce moteur ne vérifie pas ce que la base refuse aussi : partie annulée,
//      déjà commencée, complète, réservée aux adultes, joueur déjà inscrit,
//      terrain fermé à son groupe. Ces refus arrivent de la base, avec leur
//      message.
//    - La base compare le niveau à la plus petite et à la plus grande des deux
//      bornes (`least`, `greatest`) ; ce moteur suppose `niveauMin` inférieur ou
//      égal à `niveauMax` sur l'échelle. Le formulaire de création de l'app
//      refuse une fourchette inversée ; une partie créée par un autre chemin
//      qui en porterait une serait refusée ici à tort, et acceptée par la base.
//

import Foundation

/// Règles d'admission à une partie ouverte et de création d'une partie.
nonisolated enum OpenGameEligibility {

    /// Refus, avec le titre et le message exacts à afficher dans la fenêtre.
    nonisolated struct Refusal: Equatable, Sendable {
        /// Titre de la fenêtre d'alerte.
        let title: String
        /// Explication complète, avec ce que le membre peut faire.
        let message: String
    }

    /// Dit si le membre peut rejoindre une partie, et sinon pourquoi.
    ///
    /// - Parameters:
    ///   - game: partie visée.
    ///   - profile: personne qui rejoint (le compte connecté ou l'enfant au nom
    ///     de qui il agit) : son sexe et ses classements sont comparés.
    ///   - engagedSameDay: le membre participe déjà à une **autre** partie
    ///     ouverte ce jour-là. Un membre ne peut être engagé que dans une
    ///     partie par jour, tous sports confondus.
    /// - Returns: `nil` si le membre peut rejoindre.
    static func refusal(
        joining game: OpenGame,
        profile: SessionProfile,
        engagedSameDay: Bool
    ) -> Refusal? {

        // 1. Une partie par jour : le refus le plus simple à lever (quitter
        //    l'autre partie) passe en premier.
        if engagedSameDay {
            return Refusal(
                title: "Déjà une partie ce jour-là",
                message: "Vous ne pouvez participer qu'à une seule partie ouverte par jour. Quittez l'autre partie si vous préférez celle-ci."
            )
        }

        // 2. Mixité.
        if let refusal = mixityRefusal(game: game, profile: profile) {
            return refusal
        }

        // 3. Niveau.
        return levelRefusal(game: game, profile: profile)
    }

    // MARK: - Mixité

    /// - Parameters:
    ///   - game: partie visée.
    ///   - profile: personne qui rejoint.
    /// - Returns: le refus de mixité, ou `nil` pour une partie mixte ou un sexe
    ///   conforme.
    private static func mixityRefusal(game: OpenGame, profile: SessionProfile) -> Refusal? {
        // Partie mixte : aucune exigence.
        guard let required = game.mixite.requiredSexe else { return nil }

        // Sexe inconnu : on ne peut pas trancher, on demande de le renseigner.
        guard let mine = profile.sexe else {
            return Refusal(
                title: "Sexe non renseigné",
                message: "Cette partie n'est ouverte qu'à un sexe en particulier. Renseignez le vôtre dans votre profil pour pouvoir la rejoindre."
            )
        }

        guard mine != required else { return nil }

        // « réservée aux femmes » / « réservée aux hommes », selon la partie.
        let audience = required == .femme ? "aux femmes" : "aux hommes"
        return Refusal(
            title: "Partie non mixte",
            message: "L'hôte a réservé cette partie \(audience). Vous ne pouvez pas la rejoindre."
        )
    }

    // MARK: - Niveau

    /// - Parameters:
    ///   - game: partie visée.
    ///   - profile: personne qui rejoint.
    /// - Returns: le refus de niveau, ou `nil` si la partie est « tous
    ///   niveaux » ou si le classement tombe dans la fourchette.
    private static func levelRefusal(game: OpenGame, profile: SessionProfile) -> Refusal? {
        // Pas de fourchette, ou sport sans échelle : aucune exigence de niveau.
        guard let minValue = game.niveauMin, let maxValue = game.niveauMax,
              let minIndex = Ranking.index(of: minValue, sport: game.sport),
              let maxIndex = Ranking.index(of: maxValue, sport: game.sport)
        else { return nil }

        // Libellé de fourchette de `Ranking.rangeLabel` (les deux bornes reliées
        // par un tiret), sans son préfixe « Niveaux ».
        let range = Ranking.rangeLabel(min: minValue, max: maxValue, sport: game.sport)
            .replacingOccurrences(of: "Niveaux ", with: "")

        // Classement absent, ou illisible sur l'échelle : il faut le renseigner.
        guard let mine = Ranking.memberRanking(profile, sport: game.sport),
              let myIndex = Ranking.index(of: mine, sport: game.sport)
        else {
            return Refusal(
                title: "Classement non renseigné",
                message: "Cette partie demande un niveau \(range). Renseignez votre classement \(game.sport.displayName.lowercased()) dans votre profil pour pouvoir la rejoindre."
            )
        }

        let mineLabel = Ranking.display(mine, sport: game.sport)

        // L'échelle va du plus faible au plus fort : une position inférieure à
        // la borne basse veut dire un joueur moins fort que la partie.
        if myIndex < minIndex {
            return Refusal(
                title: "Niveau trop élevé pour vous",
                message: "Le niveau de cette partie (\(range)) est trop élevé par rapport à votre classement (\(mineLabel))."
            )
        }

        // Position au-delà de la borne haute : joueur plus fort que la partie.
        if myIndex > maxIndex {
            return Refusal(
                title: "Niveau trop faible pour vous",
                message: "Votre classement (\(mineLabel)) dépasse le niveau recherché par l'hôte (\(range))."
            )
        }

        return nil
    }

    // MARK: - Création

    /// Blocages qui empêchent d'ouvrir une partie, à afficher **avant** toute
    /// saisie : remplir un formulaire voué à l'échec est une perte de temps.
    nonisolated enum CreationBlock: Equatable, Sendable {
        /// Règle du club : on ne propose pas une partie sans avoir renseigné
        /// son propre niveau, sinon la fourchette demandée aux autres n'a
        /// aucun sens.
        case missingRanking(Sport)
        /// Le membre est déjà engagé dans une partie ouverte ce jour-là.
        case alreadyEngagedSameDay

        /// Titre du bandeau de blocage.
        var title: String {
            switch self {
            case .missingRanking: "Renseignez d'abord votre classement"
            case .alreadyEngagedSameDay: "Déjà une partie ce jour-là"
            }
        }

        /// Explication du blocage.
        var message: String {
            switch self {
            case .missingRanking(let sport):
                "Renseignez votre classement \(sport.displayName.lowercased()) dans votre profil pour pouvoir ouvrir une partie."
            case .alreadyEngagedSameDay:
                "Vous ne pouvez participer qu'à une seule partie ouverte par jour. Quittez l'autre partie pour en ouvrir une nouvelle."
            }
        }

        /// Libellé du bouton qui mène à la solution (profil, ou liste des
        /// parties ouvertes).
        var actionTitle: String {
            switch self {
            case .missingRanking: "Aller à mon profil"
            case .alreadyEngagedSameDay: "Voir les parties ouvertes"
            }
        }
    }

    /// Dit si le membre peut ouvrir une partie dans ce sport.
    ///
    /// - Parameters:
    ///   - sport: sport de la partie à ouvrir.
    ///   - profile: hôte de la partie.
    ///   - engagedSameDay: l'hôte participe déjà à une partie ouverte le jour
    ///     choisi.
    /// - Returns: le blocage à afficher, ou `nil` si rien n'empêche d'ouvrir.
    static func creationBlock(
        sport: Sport,
        profile: SessionProfile,
        engagedSameDay: Bool
    ) -> CreationBlock? {
        if engagedSameDay { return .alreadyEngagedSameDay }

        // Le pickleball n'a pas d'échelle : aucun classement à exiger.
        guard Ranking.hasScale(sport) else { return nil }
        guard Ranking.memberRanking(profile, sport: sport) != nil else {
            return .missingRanking(sport)
        }
        return nil
    }

    /// Mixités que le membre peut choisir à la création.
    ///
    /// L'hôte étant joueur, il ne peut pas ouvrir une partie dont il serait
    /// lui-même exclu. Sexe non renseigné ⇒ mixte uniquement.
    ///
    /// - Parameter profile: hôte de la partie.
    /// - Returns: « mixte », suivi de la mixité de son sexe s'il est connu.
    static func allowedMixities(for profile: SessionProfile) -> [Mixite] {
        guard let sexe = profile.sexe else { return [.mixte] }
        return [.mixte, sexe == .homme ? .hommes : .femmes]
    }

    /// Indication affichée sous le choix de mixité quand le sexe de l'hôte
    /// n'est pas renseigné.
    static let missingSexeNotice =
        "Renseignez votre sexe dans votre profil pour ouvrir une partie non mixte"
}
