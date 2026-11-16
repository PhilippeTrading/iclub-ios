//
//  AppConfiguration.swift
//  iClub
//
//  Rôle
//    Constantes de configuration de l'application : projet Supabase visé, club
//    de rattachement des nouveaux comptes, identifiant Google, lien de retour du
//    courriel de mot de passe oublié.
//
//  Place dans l'application
//    Lu par `Supa` (SupabaseClientProvider.swift) pour construire le client,
//    par `RootView` (`isConfigured`) et par `AuthService` (`clubId`,
//    `googleIOSClientID`, `passwordResetRedirect`).
//
//  Droits et sécurité
//    L'application parle au même projet Supabase que le site web, avec la clé
//    publique `anon` : toute la sécurité repose donc sur la base elle-même
//    (règles RLS des tables, fonctions SQL `security definer`, règles des
//    compartiments de stockage). Il n'existe qu'une base, partagée par le
//    développement, la démonstration et les clubs réels : une app de test
//    branchée ici écrit dans les vraies données.
//
//  Points d'attention
//    Changer de projet Supabase, de club de rattachement ou activer Google
//    demande une nouvelle version de l'app : rien de tout cela n'est lu à
//    distance.
//

import Foundation

/// Configuration statique de l'application.
///
/// Le web résout le club par sous-domaine ; côté mobile l'app est mono-club :
/// le club courant est déduit de l'appartenance (`club_members`) de l'utilisateur
/// connecté, il n'y a donc pas de sélecteur de club.
enum AppConfiguration {

    /// URL du projet Supabase (API REST, authentification, stockage, temps réel
    /// et fonctions serveur passent tous par cette adresse).
    static let supabaseURL = "https://wjjplbkvvomdxlgqrcjq.supabase.co"

    /// Clé publique `anon` du projet Supabase.
    /// Ne jamais embarquer la clé `service_role` dans une app cliente : elle
    /// contourne toutes les règles RLS. La clé `anon`, elle, est publique par
    /// construction ; ce qu'elle permet est borné par la RLS.
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndqanBsYmt2dm9tZHhsZ3FyY2pxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk5ODA3MTEsImV4cCI6MjEwNTU1NjcxMX0.sezePHepSR0rjJ7_RbcGJ0JqxlWzl2PPg-tXMzHFJHU"

    /// Club desservi par l'application.
    ///
    /// Partout ailleurs le club est déduit de l'appartenance de l'utilisateur
    /// (`club_members`). À l'inscription c'est impossible : le compte vient
    /// d'être créé et n'appartient encore à aucun club. Cette constante sert
    /// donc au seul appel de rattachement (`AuthService.joinClub`, fonction SQL
    /// `join_club_as_member`).
    ///
    /// Cet identifiant est celui du premier club, créé par la migration
    /// d'amorçage `20260921100434_seed_arcachon.sql` du dépôt web. Tout compte
    /// sans appartenance qui se connecte à l'app y est rattaché comme adhérent.
    /// Optionnel parce que `UUID(uuidString:)` l'est ; `nil` ferait échouer le
    /// rattachement (`AuthServiceError.clubJoinFailed`).
    static let clubId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")

    /// Identifiant client OAuth Google **de type iOS**, de la forme
    /// `xxxx.apps.googleusercontent.com`. Ce n'est pas un secret : il est fait
    /// pour être embarqué dans l'app.
    ///
    /// Le secret client de l'application *web*, lui, ne doit jamais se trouver
    /// ici : il vit uniquement dans le tableau de bord Supabase.
    ///
    /// `nil` tant qu'il n'est pas renseigné : le bouton Google explique alors
    /// que la connexion n'est pas encore activée.
    static let googleIOSClientID: String? = nil

    /// Lien de retour ouvert depuis l'email de réinitialisation de mot de passe.
    /// Doit être déclaré dans Supabase → Authentication → URL Configuration.
    ///
    /// Limite connue : le projet Xcode ne déclare aucun type d'URL `iclub`
    /// (Info.plist vide, aucune clé `CFBundleURLTypes`) et aucune vue ne traite
    /// ce lien (`onOpenURL` ne sert qu'à Google, et reste inactif). Le lien du
    /// courriel ne peut donc pas rouvrir l'app pour choisir un nouveau mot de
    /// passe ; le parcours se termine hors de l'app.
    static let passwordResetRedirect = URL(string: "iclub://reset-password")

    /// `false` tant que les identifiants Supabase n'ont pas été renseignés :
    /// l'app affiche alors un écran de configuration plutôt que de planter.
    ///
    /// Le test repère les valeurs d'exemple d'un modèle de projet
    /// (« YOUR-PROJECT », « YOUR-ANON-KEY ») ; avec les valeurs actuelles, il
    /// vaut toujours `true`.
    static var isConfigured: Bool {
        !supabaseURL.contains("YOUR-PROJECT") && !supabaseAnonKey.contains("YOUR-ANON-KEY")
    }
}
