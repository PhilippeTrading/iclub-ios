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

import Foundation

nonisolated enum PhoneNumber {

    /// Indication affichée sous le champ, en gris.
    static let hint = "10 chiffres (ex. 06 12 34 56 78) ou format international (+33 6 12 34 56 78)."

    /// Même indication, en rouge, quand le format ne passe pas.
    static let errorMessage = "Numéro de téléphone invalide. \(hint)"

    /// Retire espaces, points, tirets et parenthèses. Le `+` d'un numéro
    /// international est conservé, mais seulement en tête.
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
    static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)

        if normalized.hasPrefix("+") {
            let digits = normalized.dropFirst()
            return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
        }

        return normalized.count == 10
            && normalized.hasPrefix("0")
            && normalized.allSatisfy(\.isNumber)
    }

    /// Affichage lisible : « 0612345678 » devient « 06 12 34 56 78 ».
    ///
    /// Les numéros internationaux sont rendus tels quels — leur découpage varie
    /// selon les pays, et un regroupement arbitraire serait faux plus souvent
    /// qu'utile.
    ///
    /// - Returns: `nil` si aucun numéro n'est enregistré. Les comptes créés
    ///   avant l'ajout de ce champ n'en ont pas : l'app ne doit jamais supposer
    ///   qu'un numéro existe.
    static func formattedForDisplay(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }

        guard normalized.count == 10, !normalized.hasPrefix("+") else {
            return normalized
        }

        return stride(from: 0, to: normalized.count, by: 2)
            .map { offset in
                let start = normalized.index(normalized.startIndex, offsetBy: offset)
                let end = normalized.index(start, offsetBy: 2)
                return String(normalized[start..<end])
            }
            .joined(separator: " ")
    }
}
