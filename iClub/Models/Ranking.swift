//
//  Ranking.swift
//  iClub
//
//  Échelles de classement, et comparaisons.
//
//  Le classement tennis FFT **n'est pas ordonnable alphabétiquement** :
//  « 30/1 » est plus fort que « 30/5 », « -15 » plus fort que « 0 », et « NC »
//  est le plus faible de tous. Toute comparaison passe donc par la position
//  dans le tableau `tennisScale`, jamais par la chaîne elle-même.
//
//  Le padel va de 1,0 à 10,0 par pas de 0,5. Il est stocké avec un point
//  (colonne numérique) et affiché avec une virgule.
//
//  Le pickleball n'a pas de classement au club : une partie y est toujours
//  « tous niveaux ».
//

import Foundation

nonisolated enum Ranking {

    /// Du plus faible au plus fort. L'ordre de ce tableau *est* la règle.
    static let tennisScale = [
        "NC", "40", "30/5", "30/4", "30/3", "30/2", "30/1", "30",
        "15/5", "15/4", "15/3", "15/2", "15/1", "15",
        "5/6", "4/6", "3/6", "2/6", "1/6", "0",
        "-2/6", "-4/6", "-15", "-30",
    ]

    /// 1,0 → 10,0 par pas de 0,5, du plus faible au plus fort.
    static let padelScale: [Double] = stride(from: 1.0, through: 10.0, by: 0.5).map { $0 }

    // MARK: - Échelle d'un sport

    /// Valeurs stockables pour un sport, dans l'ordre croissant de niveau.
    /// Vide en pickleball, où il n'y a pas d'échelle.
    static func scale(for sport: Sport) -> [String] {
        switch sport {
        case .tennis: tennisScale
        case .padel: padelScale.map(stored(padel:))
        case .pickleball: []
        }
    }

    static func hasScale(_ sport: Sport) -> Bool {
        !scale(for: sport).isEmpty
    }

    // MARK: - Représentations

    /// Valeur telle qu'écrite en base : point décimal, pas de virgule.
    static func stored(padel value: Double) -> String {
        // `%g` supprimerait le « .0 » ; on veut « 4.0 » et non « 4 », pour
        // rester identique à ce que le web écrit.
        String(format: "%.1f", value)
    }

    /// Valeur affichée : le padel prend une virgule, le tennis reste tel quel.
    static func display(_ value: String, sport: Sport) -> String {
        guard sport == .padel else { return value }
        guard let number = Double(value) else { return value }
        return number.formatted(
            .number.precision(.fractionLength(1)).locale(AppLocale.french)
        )
    }

    /// Fourchette lisible : « Niveaux 4,0 – 5,0 », ou « Tous niveaux ».
    static func rangeLabel(min: String?, max: String?, sport: Sport) -> String {
        guard let min, let max, !min.isEmpty, !max.isEmpty else { return "Tous niveaux" }
        return "Niveaux \(display(min, sport: sport)) – \(display(max, sport: sport))"
    }

    // MARK: - Comparaison

    /// Position sur l'échelle, `nil` si la valeur n'y figure pas.
    static func index(of value: String?, sport: Sport) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        let scale = scale(for: sport)

        if let exact = scale.firstIndex(of: value) { return exact }

        // Le padel peut arriver sous une forme numériquement équivalente mais
        // écrite différemment (« 4 » au lieu de « 4.0 ») : on compare alors les
        // nombres plutôt que les chaînes.
        guard sport == .padel, let number = Double(value) else { return nil }
        return padelScale.firstIndex { $0 == number }
    }

    /// Classement du membre pour ce sport, tel que stocké.
    static func memberRanking(_ profile: SessionProfile, sport: Sport) -> String? {
        switch sport {
        case .tennis:
            guard let value = profile.classementTennis, !value.isEmpty else { return nil }
            return value
        case .padel:
            guard let value = profile.classementPadel else { return nil }
            return stored(padel: value)
        case .pickleball:
            return nil
        }
    }

    // MARK: - Pré-remplissage

    /// Fourchette proposée par défaut à la création : un cran en dessous et un
    /// cran au-dessus du classement de l'hôte, bornée aux extrémités.
    ///
    /// Exemples attendus : 30/1 → 30/2 – 30 ; NC → NC – 40 ; -30 → -15 – -30.
    static func suggestedRange(around value: String, sport: Sport) -> (min: String, max: String)? {
        let scale = scale(for: sport)
        guard let position = index(of: value, sport: sport), !scale.isEmpty else { return nil }

        let lower = max(0, position - 1)
        let upper = min(scale.count - 1, position + 1)
        return (scale[lower], scale[upper])
    }
}
