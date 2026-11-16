//
//  SupabaseClientProvider.swift
//  iClub
//
//  Rôle
//    Construit et expose l'unique client du SDK Supabase Swift (paquet
//    supabase-swift, version 2.55 ou plus récente dans la même version majeure).
//
//  Place dans l'application
//    `Supa.client` est utilisé par toute la couche Services/ (requêtes PostgREST
//    `.from(...)`, fonctions SQL `.rpc(...)`, stockage `.storage`, fonctions
//    serveur `.functions`), par `AuthController` (flux `authStateChanges`) et par
//    `ClubCatalog` (canal temps réel sur `courts`).
//
//  Droits et sécurité
//    Le client est construit avec la clé publique `anon`. Une fois le membre
//    connecté, le SDK joint le jeton de sa session à chaque appel : la base voit
//    alors `auth.uid()`, et la RLS s'applique au nom du membre. La session est
//    conservée par le SDK d'un lancement à l'autre (stockage par défaut du SDK)
//    et rafraîchie par lui.
//

import Foundation
import Supabase

/// Point d'accès unique au client Supabase partagé par toute la couche `Services/`.
///
/// Nommé `Supa` et non `Supabase` pour ne pas masquer le module du SDK.
enum Supa {

    /// Client partagé, créé paresseusement au premier accès puis réutilisé.
    /// `nonisolated` : il est lu depuis n'importe quel contexte, y compris hors
    /// de l'acteur principal sur lequel le projet isole tout par défaut ; le
    /// type `SupabaseClient` du SDK est `Sendable`, ce partage est donc permis.
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
