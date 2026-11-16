//
//  PhoneNumber.swift
//  iClub
//
//  Normalisation, validation et affichage du numéro de téléphone.
//
//  C'est toujours la version *normalisée* (chiffres seuls, `+` conservé) qui
//  part en base, jamais la saisie brute : c'est ce qui garantit un format
//  homogène, identique à celui écrit par le web.
//
//  Place dans l'application
//    Inscription (`AuthService.signUp`, métadonnées recopiées dans
//    `profiles.telephone` par le déclencheur `handle_new_user`), complétion et
//    édition du profil (`ProfileService.updatePersonalInfo`), affichage du
//    numéro dans le profil, les fiches d'élève et l'écran d'adhésion.
//
//  Points d'attention
//    La base ne contrôle pas le format de `profiles.telephone` : la règle
//    n'existe que dans les applications. `Character.isNumber` accepte aussi des
//    chiffres d'autres écritures que la latine ; une saisie au clavier iOS
//    standard n'en produit pas.
//

import Foundation

/// Règles du numéro de téléphone d'un membre.
nonisolated enum PhoneNumber {

    /// Indication affichée sous le champ, en gris.
    static let hint = "10 chiffres (ex. 06 12 34 56 78) ou format international (+33 6 12 34 56 78)."

    /// Même indication, en rouge, quand le format ne passe pas.
    static let errorMessage = "Numéro de téléphone invalide. \(hint)"

    /// Retire espaces, points, tirets et parenthèses. Le `+` d'un numéro
    /// international est conservé, mais seulement en tête.
    ///
    /// - Parameter value: saisie brute.
    /// - Returns: chiffres seuls, précédés d'un `+` si la saisie commençait par
    ///   un `+`. Tout autre caractère (lettre, `+` placé ailleurs) est retiré.
    static func normalize(_ value: String) -> String {
        let stripped = value
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[\\s.\\-()]", with: "", options: .regularExpression)

        if stripped.hasPrefix("+") {
            return "+" + stripped.dropFirst().filter(\.isNumber)
        }
        return stripped.filter(\.isNumber)
    }

    /// Deux formats acceptés : français à 10 chiffres commençant par 0, ou
    /// international `+` suivi de 8 à 15 chiffres.
    ///
    /// - Parameter value: saisie brute (elle est normalisée avant le test).
    /// - Returns: `true` si le numéro peut être enregistré.
    static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)

        // International : 8 à 15 chiffres après le `+` (15 est le maximum de
        // la norme internationale de numérotation).
        if normalized.hasPrefix("+") {
            let digits = normalized.dropFirst()
            return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
        }

        // Français : 0 suivi de 9 chiffres.
        return normalized.count == 10
            && normalized.hasPrefix("0")
            && normalized.allSatisfy(\.isNumber)
    }

    /// Affichage lisible : « 0612345678 » devient « 06 12 34 56 78 ».
    ///
    /// Les numéros internationaux sont rendus tels quels : leur découpage varie
    /// selon les pays, et un regroupement arbitraire serait faux plus souvent
    /// qu'utile.
    ///
    /// - Parameter value: numéro tel qu'enregistré, ou `nil`.
    /// - Returns: `nil` si aucun numéro n'est enregistré. Les comptes créés
    ///   avant l'ajout de ce champ n'en ont pas : l'app ne doit jamais supposer
    ///   qu'un numéro existe.
    static func formattedForDisplay(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }

        // Tout ce qui n'est pas un numéro à 10 chiffres sans `+` est rendu
        // normalisé, sans regroupement.
        guard normalized.count == 10, !normalized.hasPrefix("+") else {
            return normalized
        }

        // Groupes de deux chiffres séparés par une espace.
        return stride(from: 0, to: normalized.count, by: 2)
            .map { offset in
                let start = normalized.index(normalized.startIndex, offsetBy: offset)
                let end = normalized.index(start, offsetBy: 2)
                return String(normalized[start..<end])
            }
            .joined(separator: " ")
    }
}
