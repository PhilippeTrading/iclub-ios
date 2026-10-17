//
//  PriceFormatting.swift
//  iClub
//
//  Règle d'affichage du tarif, identique au web :
//
//  • un membre avec une adhésion active ne voit **aucun prix**, nulle part ;
//  • sinon on affiche le prix par joueur, soit
//    `courts.tarif_prix_total / courts.tarif_capacite`.
//
//  Centralisé ici pour qu'aucun écran n'improvise sa propre règle.
//

import Foundation

/// Constantes tarifaires du tunnel de réservation.
nonisolated enum BookingPricing {

    /// Supplément dû par invité dont la part n'est pas prise sur un crédit.
    /// Valeur métier appliquée à l'identique par le web, non paramétrable en
    /// base à ce jour.
    static let guestSupplement: Double = 10
}

enum Price {

    /// « 12,50 € », toujours en euros et en format français.
    static func perPlayer(_ value: Double) -> String {
        amount(value)
    }

    /// Montant formaté, utilisé aussi par le détail du récapitulatif.
    static func amount(_ value: Double) -> String {
        value.formatted(
            .currency(code: "EUR")
                .locale(AppLocale.french)
        )
    }

    /// Prix par joueur à afficher pour une sélection de terrains.
    ///
    /// - Returns: `nil` si le membre a une adhésion active, ou si aucun terrain
    ///   ne porte de tarif renseigné. Si les terrains ont des tarifs différents,
    ///   le moins cher est annoncé, préfixé de « dès » — jamais un prix unique
    ///   qui serait faux pour une partie de la liste.
    static func label(for courts: [Court], hasActiveMembership: Bool) -> String? {
        guard !hasActiveMembership else { return nil }

        let prices = courts.compactMap(\.pricePerPlayer)
        guard let cheapest = prices.min() else { return nil }

        let isUniform = prices.allSatisfy { $0 == cheapest }
        return isUniform ? perPlayer(cheapest) : "dès \(perPlayer(cheapest))"
    }
}
