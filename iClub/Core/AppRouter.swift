//
//  AppRouter.swift
//  iClub
//
//  Navigation transverse aux onglets : l'accueil doit pouvoir ouvrir le
//  planning d'un sport donné, qui vit dans l'onglet « Réserver ».
//

import Foundation
import Observation
import SwiftUI

@Observable
final class AppRouter {
    var selectedTab: AppTab = .home

    /// Pile de navigation de l'onglet « Réserver ». Portée par le routeur et
    /// non par la vue : l'écran de confirmation doit pouvoir refermer le tunnel
    /// derrière lui, pour que le geste arrière ne ramène pas dans un
    /// récapitulatif dont la réservation est déjà enregistrée.
    var bookingPath = NavigationPath()

    /// Pile de navigation de l'onglet « Parties ». Même raison que pour la
    /// réservation : l'écran de confirmation referme le tunnel derrière lui.
    var openGamesPath = NavigationPath()

    /// Pile de l'accueil, qui ouvre le détail d'une réservation.
    var homePath = NavigationPath()

    /// Sport affiché par le tunnel de réservation. Porté par le routeur plutôt
    /// que par un `@State` local à l'écran : la valeur survit aux recréations
    /// de vue lors d'un changement d'onglet, et l'onglet se souvient du dernier
    /// sport consulté.
    var bookingSport: Sport?

    /// Jour affiché par la bande de dates. `nil` signifie « aujourd'hui » et
    /// n'est délibérément pas remplacé par une `Date` calculée à l'init : l'app
    /// peut rester ouverte au passage de minuit, et une valeur figée
    /// afficherait alors la veille comme jour courant.
    var bookingDate: Date?

    /// Surface retenue par le filtre du tunnel de réservation. `nil` = « Tout ».
    /// Portée par le routeur pour que le filtre choisi à l'écran des créneaux
    /// reste actif sur l'écran de choix du terrain, et survive à un aller-retour.
    var bookingSurface: String?

    func openBooking(for sport: Sport) {
        bookingSport = sport
        selectedTab = .book
    }

    /// Remet toute la navigation à zéro. Les piles peuvent porter des données
    /// du compte (noms de participants d'une confirmation, par exemple) : après
    /// une suppression de compte, il ne doit rien en rester.
    func reset() {
        selectedTab = .home
        bookingPath = NavigationPath()
        openGamesPath = NavigationPath()
        homePath = NavigationPath()
        bookingSport = nil
        bookingDate = nil
        bookingSurface = nil
    }

    /// Referme le tunnel de réservation et revient à l'accueil.
    func closeBookingFlow() {
        bookingPath = NavigationPath()
        selectedTab = .home
    }
}
