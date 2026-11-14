//
//  GoogleSignInButtonView.swift
//  iClub
//
//  « Continuer avec Google ».
//
//  Le bouton officiel du SDK est utilisé tel quel : la charte de Google impose
//  le logo, le libellé et les proportions. Le SDK est derrière `canImport` :
//  sans lui, cette vue est vide et l'écran de connexion n'en sait rien.
//
//  Rôle
//    Bouton de connexion Google de l'écran de connexion (`SignInView`).
//    Fonctionnalité EN SOMMEIL, volontairement : le paquet GoogleSignIn-iOS
//    n'est pas dans le projet, la vue est donc vide dans la version actuelle.
//    Ce n'est pas du code mort : il s'activera de lui-même quand le paquet
//    sera ajouté (marche à suivre dans AuthService.swift, rubrique
//    « Connexion avec Google »).
//
//  Déroulé, une fois activé
//    Feuille Google native, puis échange du jeton d'identité contre une
//    session Supabase (`AuthService.signInWithGoogle`). La suite (profil,
//    rattachement au club, complétion) est pilotée par `AuthController`.
//
//  Points d'attention
//    Cette vue teste le module `GoogleSignInSwift` (le bouton), alors que
//    `AuthService.isGoogleSignInAvailable`, qui décide de l'afficher, teste
//    `GoogleSignIn`. Il faut donc ajouter les deux produits du paquet : avec le
//    seul `GoogleSignIn`, l'écran de connexion poserait ici une vue vide.
//

import SwiftUI
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

/// Bouton officiel « Continuer avec Google », vide tant que le SDK Google
/// n'est pas intégré au projet.
struct GoogleSignInButtonView: View {
    /// Appelé en cas d'échec, pour afficher le message dans l'écran parent.
    /// Reçoit un message prêt à afficher.
    let onError: (String) -> Void

    /// Apparence claire ou sombre, pour la variante du bouton Google.
    @Environment(\.colorScheme) private var colorScheme
    /// Vrai pendant la connexion : le bouton passe à l'état désactivé.
    @State private var isSigningIn = false

    /// Le bouton officiel de Google si le SDK est présent, rien sinon.
    var body: some View {
        // SDK présent : le bouton officiel, large, aux couleurs du thème.
        #if canImport(GoogleSignInSwift)
        GoogleSignInButton(
            viewModel: GoogleSignInButtonViewModel(
                scheme: colorScheme == .dark ? .dark : .light,
                style: .wide,
                state: isSigningIn ? .disabled : .normal
            )
        ) {
            signIn()
        }
        .frame(height: 52)
        .accessibilityLabel("Continuer avec Google")
        // SDK absent (cas de la version actuelle) : rien à l'écran.
        #else
        EmptyView()
        #endif
    }

    /// Lance la connexion Google et signale l'issue : vibration de succès, ou
    /// message d'erreur transmis à l'écran parent.
    private func signIn() {
        isSigningIn = true
        Task {
            do {
                // `false` : feuille fermée par l'utilisateur. Ce n'est pas une
                // erreur, on revient simplement à l'écran de connexion.
                if try await AuthService.signInWithGoogle() {
                    Haptics.success()
                }
            } catch {
                onError(error.localizedDescription)
                Haptics.warning()
            }
            isSigningIn = false
        }
    }
}
