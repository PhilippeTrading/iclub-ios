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

import Foundation

nonisolated enum OpenGameEligibility {

    /// Refus, avec le titre et le message exacts à afficher dans la fenêtre.
    nonisolated struct Refusal: Equatable, Sendable {
        let title: String
        let message: String
    }

    /// - Parameters:
    ///   - engagedSameDay: le membre participe déjà à une **autre** partie
    ///     ouverte ce jour-là. Un membre ne peut être engagé que dans une
    ///     partie par jour, tous sports confondus.
    /// - Returns: `nil` si le membre peut rejoindre.
    static func refusal(
        joining game: OpenGame,
        profile: SessionProfile,
        engagedSameDay: Bool
    ) -> Refusal? {

        if engagedSameDay {
            return Refusal(
                title: "Déjà une partie ce jour-là",
                message: "Vous ne pouvez participer qu'à une seule partie ouverte par jour. Quittez l'autre partie si vous préférez celle-ci."
            )
        }

        if let refusal = mixityRefusal(game: game, profile: profile) {
            return refusal
        }

        return levelRefusal(game: game, profile: profile)
    }

    // MARK: - Mixité

    private static func mixityRefusal(game: OpenGame, profile: SessionProfile) -> Refusal? {
        guard let required = game.mixite.requiredSexe else { return nil }

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

    private static func levelRefusal(game: OpenGame, profile: SessionProfile) -> Refusal? {
        // Pas de fourchette, ou sport sans échelle : aucune exigence de niveau.
        guard let minValue = game.niveauMin, let maxValue = game.niveauMax,
              let minIndex = Ranking.index(of: minValue, sport: game.sport),
              let maxIndex = Ranking.index(of: maxValue, sport: game.sport)
        else { return nil }

        let range = Ranking.rangeLabel(min: minValue, max: maxValue, sport: game.sport)
            .replacingOccurrences(of: "Niveaux ", with: "")

        guard let mine = Ranking.memberRanking(profile, sport: game.sport),
              let myIndex = Ranking.index(of: mine, sport: game.sport)
        else {
            return Refusal(
                title: "Classement non renseigné",
                message: "Cette partie demande un niveau \(range). Renseignez votre classement \(game.sport.displayName.lowercased()) dans votre profil pour pouvoir la rejoindre."
            )
        }

        let mineLabel = Ranking.display(mine, sport: game.sport)

        if myIndex < minIndex {
            return Refusal(
                title: "Niveau trop élevé pour vous",
                message: "Le niveau de cette partie (\(range)) est trop élevé par rapport à votre classement (\(mineLabel))."
            )
        }

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
        case alreadyEngagedSameDay

        var title: String {
            switch self {
            case .missingRanking: "Renseignez d'abord votre classement"
            case .alreadyEngagedSameDay: "Déjà une partie ce jour-là"
            }
        }

        var message: String {
            switch self {
            case .missingRanking(let sport):
                "Renseignez votre classement \(sport.displayName.lowercased()) dans votre profil pour pouvoir ouvrir une partie."
            case .alreadyEngagedSameDay:
                "Vous ne pouvez participer qu'à une seule partie ouverte par jour. Quittez l'autre partie pour en ouvrir une nouvelle."
            }
        }

        var actionTitle: String {
            switch self {
            case .missingRanking: "Aller à mon profil"
            case .alreadyEngagedSameDay: "Voir les parties ouvertes"
            }
        }
    }

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
    static func allowedMixities(for profile: SessionProfile) -> [Mixite] {
        guard let sexe = profile.sexe else { return [.mixte] }
        return [.mixte, sexe == .homme ? .hommes : .femmes]
    }

    static let missingSexeNotice =
        "Renseignez votre sexe dans votre profil pour ouvrir une partie non mixte"
}
