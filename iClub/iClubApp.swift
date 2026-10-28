//
//  iClubApp.swift
//  iClub
//
//  Created by Philippe Delage on 22/09/2026.
//

import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct iClubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Contrôleur de session global, injecté en environnement et consulté par
    /// tous les écrans pour connaître le membre connecté.
    @State private var auth = AuthController()

    /// Terrains et horaires du club, chargés depuis Supabase et tenus à jour en
    /// temps réel : rien de tout cela n'est codé en dur dans l'app.
    @State private var catalog = ClubCatalog()

    /// Navigation transverse aux onglets.
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
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
                // de l'identifiant client inversé.
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
                #endif
        }
    }
}
