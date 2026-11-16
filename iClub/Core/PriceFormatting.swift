//
//  PriceFormatting.swift
//  iClub
//
//  Règle d'affichage du tarif, identique au web lors de son écriture :
//
//  • un membre avec une adhésion active ne voit **aucun prix**, nulle part ;
//  • sinon on affiche le prix par joueur, soit
//    `courts.tarif_prix_total / courts.tarif_capacite`.
//
//  Centralisé ici pour qu'aucun écran n'improvise sa propre règle.
//
//  Place dans l'application
//    `Price.label` : prix affiché sur le planning (`BookingView`) et sur le
//    choix du terrain (`CourtPickerView`). `Price.amount` : tout montant en
//    euros (récapitulatif, invité, adhésion, reçus). `BookingPricing` : le
//    supplément invité du tunnel de réservation (`BookingParticipant`,
//    `GuestFormSheet`).
//
//  Points d'attention
//    Les montants sont des `Double` en euros (pas en centimes), comme les
//    colonnes `numeric` de la base qu'ils reflètent. Le web a depuis fait
//    évoluer son calcul : il applique des plages tarifaires (table
//    `plages_tarifaires`) et fait payer la part du créneau (prix du terrain
//    divisé par le nombre de joueurs du format) aux invités sans crédit comme
//    aux membres sans adhésion à jour (voir `src/lib/actions/reservations.ts`
//    du dépôt web). L'app ne reprend pas ces règles.
//

import Foundation

/// Constantes tarifaires du tunnel de réservation.
nonisolated enum BookingPricing {

    /// Supplément dû par invité dont la part n'est pas prise sur un crédit,
    /// en euros. Valeur métier non paramétrable en base à ce jour.
    ///
    /// Attention : le web ne facture plus un montant fixe mais la part du
    /// créneau (prix du terrain divisé par 2 en simple, par 4 en double). Les
    /// totaux calculés par l'app et par le web peuvent donc différer.
    static let guestSupplement: Double = 10
}

/// Mise en forme des prix et règle de leur affichage.
enum Price {

    /// « 12,50 € », toujours en euros et en format français.
    ///
    /// - Parameter value: montant en euros.
    /// - Returns: le montant mis en forme.
    static func perPlayer(_ value: Double) -> String {
        amount(value)
    }

    /// Montant formaté, utilisé aussi par le détail du récapitulatif.
    ///
    /// - Parameter value: montant en euros (décimales comprises).
    /// - Returns: montant au format monétaire français, avec le symbole €.
    static func amount(_ value: Double) -> String {
        value.formatted(
            .currency(code: "EUR")
                .locale(AppLocale.french)
        )
    }

    /// Prix par joueur à afficher pour une sélection de terrains.
    ///
    /// - Parameters:
    ///   - courts: terrains concernés (ceux d'un créneau, ou un seul terrain).
    ///   - hasActiveMembership: le membre au nom de qui l'on réserve a une
    ///     adhésion active ; il ne voit alors aucun prix.
    /// - Returns: `nil` si le membre a une adhésion active, ou si aucun terrain
    ///   ne porte de tarif renseigné. Si les terrains ont des tarifs différents,
    ///   le moins cher est annoncé, préfixé de « dès », jamais un prix unique
    ///   qui serait faux pour une partie de la liste.
    static func label(for courts: [Court], hasActiveMembership: Bool) -> String? {
        guard !hasActiveMembership else { return nil }

        // Terrains sans tarif exploitable ignorés (voir `Court.pricePerPlayer`).
        let prices = courts.compactMap(\.pricePerPlayer)
        guard let cheapest = prices.min() else { return nil }

        let isUniform = prices.allSatisfy { $0 == cheapest }
        return isUniform ? perPlayer(cheapest) : "dès \(perPlayer(cheapest))"
    }
}
