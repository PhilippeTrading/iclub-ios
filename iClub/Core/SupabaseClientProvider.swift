//
//  SupabaseClientProvider.swift
//  iClub
//

import Foundation
import Supabase

/// Point d'accès unique au client Supabase partagé par toute la couche `Services/`.
///
/// Nommé `Supa` et non `Supabase` pour ne pas masquer le module du SDK.
enum Supa {

    nonisolated static let client: SupabaseClient = {
        // `isConfigured` est vérifié en amont par `RootView` : si la configuration
        // est absente on construit tout de même un client inerte pointant sur une
        // URL factice, de façon à ne jamais faire planter le lancement de l'app.
        let url = URL(string: AppConfiguration.supabaseURL)
            ?? URL(string: "https://unconfigured.supabase.co")!

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfiguration.supabaseAnonKey
        )
    }()
}
