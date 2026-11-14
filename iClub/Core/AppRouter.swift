//
//  AppRouter.swift
//  iClub
//
//  Navigation transverse aux onglets : l'accueil doit pouvoir ouvrir le
//  planning d'un sport donné, qui vit dans l'onglet « Réserver ».
//
//  Rôle
//    État de navigation partagé par toute l'app : onglet sélectionné, pile de
//    chaque onglet (`NavigationPath`), et choix du tunnel de réservation (sport,
//    jour, surface) qui doivent survivre à un changement d'onglet.
//
//  Place dans l'application
//    Créé une fois par `iClubApp` et injecté en environnement. `MainTabView`
//    lie chaque `NavigationStack` à la pile correspondante ; l'accueil, les
//    écrans de confirmation, la barre du haut (changement de profil famille) et
//    la suppression de compte le pilotent par les méthodes ci-dessous.
//
//  Effets de bord
//    Aucun accès réseau ni écriture : uniquement de l'état en mémoire, perdu à
//    la fermeture de l'app.
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage par défaut du
//    projet) : toute modification redessine les vues qui lisent la propriété.
//

import Foundation
import Observation
import SwiftUI

/// Routeur de l'application : onglet actif, piles de navigation et contexte
/// du tunnel de réservation.
@Observable
final class AppRouter {
    /// Onglet affiché par la barre d'onglets. L'accueil au lancement.
    var selectedTab: AppTab = .home

    /// Pile de l'onglet « Activités » (intitulé « Cours » dans la barre
    /// d'onglets) : liste des cours, détail, espace entraîneur.
    var activitiesPath = NavigationPath()

    /// Pile de navigation de l'onglet « Réserver », dont la racine est la
    /// réservation d'un créneau. Portée par le routeur et
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

    /// Ouvre le planning d'un sport, à la racine de l'onglet « Réserver ».
    /// Appelé par les raccourcis par sport de l'accueil.
    ///
    /// - Parameter sport: sport à afficher ; remplace le dernier consulté.
    func openBooking(for sport: Sport) {
        bookingSport = sport
        // Pile vidée : on arrive sur le planning, pas sur un écran resté
        // ouvert lors d'une visite précédente de l'onglet.
        bookingPath = NavigationPath()
        selectedTab = .reservations
    }

    /// Remet toute la navigation à zéro. Les piles peuvent porter des données
    /// du compte (noms de participants d'une confirmation, par exemple) : après
    /// une suppression de compte, il ne doit rien en rester.
    ///
    /// Appelé aussi par la barre du haut quand le parent change de profil
    /// (lui-même ou un enfant) : elle remet ensuite l'onglet courant.
    func reset() {
        selectedTab = .home
        bookingPath = NavigationPath()
        activitiesPath = NavigationPath()
        openGamesPath = NavigationPath()
        homePath = NavigationPath()
        bookingSport = nil
        bookingDate = nil
        bookingSurface = nil
    }

    /// Onglet « Réservations », à la racine : la réservation d'un créneau.
    /// Le sport affiché reste le dernier consulté.
    func openBooking() {
        bookingPath = NavigationPath()
        selectedTab = .reservations
    }

    /// Historique des réservations, poussé sur la racine de l'onglet.
    /// Appelé au tap sur un rappel de réservation (voir `MainTabView`).
    func openReservationHistory() {
        var path = NavigationPath()
        path.append(ReservationHistoryRoute())
        bookingPath = path
        selectedTab = .reservations
    }

    /// Referme le tunnel de réservation et revient à l'accueil.
    /// Appelé par l'écran de confirmation d'une réservation.
    func closeBookingFlow() {
        bookingPath = NavigationPath()
        selectedTab = .home
    }
}
