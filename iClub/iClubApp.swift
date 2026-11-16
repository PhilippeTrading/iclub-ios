//
//  iClubApp.swift
//  iClub
//
//  Created by Philippe Delage on 22/09/2026.
//
//  Rôle
//    Point d'entrée de l'application (`@main`). Crée une seule fois les objets
//    partagés par tous les écrans et les injecte dans l'environnement SwiftUI de
//    l'unique fenêtre, dont la racine est `RootView` (Features/Root).
//
//  Architecture de l'application, couche par couche
//    - Core/ : configuration (`AppConfiguration`), client Supabase unique
//      (`Supa`), contrôleurs globaux observables (`AuthController`,
//      `ClubCatalog`, `AppRouter`), délégué UIKit (`AppDelegate`), moteurs de
//      règles purs (`AvailabilityEngine`, `OpenGameEligibility`) et
//      utilitaires de mise en forme (dates, prix, téléphone).
//    - Models/ : structures décodées depuis la base (suffixe `Row`), charges
//      utiles d'écriture (`Insert`, `Update`, `Params`) et types du domaine que
//      les écrans affichent.
//    - Services/ : seuls à parler à Supabase (tables, vues, fonctions SQL
//      appelées par `rpc`, compartiments de stockage, fonctions serveur). Aucune
//      vue n'appelle le SDK directement.
//    - Features/ : écrans SwiftUI et leurs magasins d'état (`…Store`).
//    - DesignSystem/ : couleurs, typographie et composants visuels communs.
//
//  Objets injectés dans l'environnement
//    - `AuthController` : session, profil du membre connecté, compte famille.
//    - `ClubCatalog` : terrains et horaires du club, tenus à jour en temps réel.
//    - `AppRouter` : onglet actif et piles de navigation partagées.
//    - `MessagingCenter.shared` : la feuille de messagerie, unique pour l'app.
//    - La locale française, imposée à toute l'interface.
//
//  Points d'attention
//    - La connexion Google est en sommeil : le paquet GoogleSignIn n'est pas
//      dans le projet (seul le paquet supabase-swift l'est), les blocs
//      `#if canImport(GoogleSignIn)` sont donc écartés à la compilation (voir
//      AuthService.swift).
//    - Aucun autre lien entrant n'est traité ici : le retour de la page de
//      paiement Stripe est capté par la session web sécurisée de l'écran
//      d'adhésion, et le lien de réinitialisation du mot de passe n'a pas de
//      gestionnaire (voir `AppConfiguration.passwordResetRedirect`).
//
//  Fil d'exécution
//    Tout le projet est isolé par défaut sur l'acteur principal (réglage
//    `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` du projet Xcode) : un type ou une
//    fonction qui doit vivre hors de cet acteur est marqué `nonisolated`.
//

import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// Application iClub : une scène, une fenêtre, et les objets globaux de session.
@main
struct iClubApp: App {
    /// Délégué UIKit pour ce que SwiftUI ne couvre pas seul : enregistrement
    /// APNs (jeton d'appareil) et délégué des notifications (voir AppDelegate.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Contrôleur de session global, injecté en environnement et consulté par
    /// tous les écrans pour connaître le membre connecté.
    @State private var auth = AuthController()

    /// Terrains et horaires du club, chargés depuis Supabase et tenus à jour en
    /// temps réel : rien de tout cela n'est codé en dur dans l'app.
    @State private var catalog = ClubCatalog()

    /// Navigation transverse aux onglets.
    @State private var router = AppRouter()

    /// Scène unique de l'application. `RootView` choisit ensuite l'écran à
    /// montrer (configuration absente, connexion, profil à compléter, onglets)
    /// selon l'état de `auth`.
    var body: some Scene {
        WindowGroup {
            RootView()
                // Les trois objets globaux, lus par les vues avec
                // `@Environment(AuthController.self)` et équivalents.
                .environment(auth)
                .environment(catalog)
                .environment(router)
                // Unique : la bulle, les boutons « Écrire » et le tap sur une
                // notification agissent sur la même feuille de messagerie.
                .environment(MessagingCenter.shared)
                // Toute l'interface est en français : les contrôles système
                // (sélecteur de date, formats de nombres) doivent suivre, même
                // si l'appareil est configuré dans une autre langue.
                .environment(\.locale, AppLocale.french)
                #if canImport(GoogleSignIn)
                // Retour de la feuille Google vers l'app, via le schéma d'URL
                // de l'identifiant client inversé. Compilé seulement si le
                // paquet GoogleSignIn est ajouté au projet.
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
                #endif
        }
    }
}
