//
//  GoogleSignInButtonView.swift
//  iClub
//
//  « Continuer avec Google ».
//
//  Le bouton officiel du SDK est utilisé tel quel : la charte de Google impose
//  le logo, le libellé et les proportions. Le SDK est derrière `canImport` —
//  sans lui, cette vue est vide et l'écran de connexion n'en sait rien.
//

import SwiftUI
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

struct GoogleSignInButtonView: View {
    /// Appelé en cas d'échec, pour afficher le message dans l'écran parent.
    let onError: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isSigningIn = false

    var body: some View {
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
        #else
        EmptyView()
        #endif
    }

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
