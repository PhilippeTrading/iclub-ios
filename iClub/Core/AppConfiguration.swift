//
//  AppConfiguration.swift
//  iClub
//

import Foundation

/// Configuration statique de l'application.
///
/// Le web résout le club par sous-domaine ; côté mobile l'app est mono-club :
/// le club courant est déduit de l'appartenance (`club_members`) de l'utilisateur
/// connecté, il n'y a donc pas de sélecteur de club.
enum AppConfiguration {

    /// URL du projet Supabase.
    static let supabaseURL = "https://wjjplbkvvomdxlgqrcjq.supabase.co"

    /// Clé publique `anon` du projet Supabase.
    /// Ne jamais embarquer la clé `service_role` dans une app cliente.
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndqanBsYmt2dm9tZHhsZ3FyY2pxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk5ODA3MTEsImV4cCI6MjEwNTU1NjcxMX0.sezePHepSR0rjJ7_RbcGJ0JqxlWzl2PPg-tXMzHFJHU"

    /// Club desservi par l'application.
    ///
    /// Partout ailleurs le club est déduit de l'appartenance de l'utilisateur
    /// (`club_members`). À l'inscription c'est impossible : le compte vient
    /// d'être créé et n'appartient encore à aucun club. Cette constante sert
    /// donc au seul appel de rattachement.
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
    static let passwordResetRedirect = URL(string: "iclub://reset-password")

    /// `false` tant que les identifiants Supabase n'ont pas été renseignés :
    /// l'app affiche alors un écran de configuration plutôt que de planter.
    static var isConfigured: Bool {
        !supabaseURL.contains("YOUR-PROJECT") && !supabaseAnonKey.contains("YOUR-ANON-KEY")
    }
}
