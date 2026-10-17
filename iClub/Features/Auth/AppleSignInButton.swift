//
//  AppleSignInButton.swift
//  iClub
//
//  « Se connecter avec Apple », avec le bouton système.
//
//  Le bouton officiel `SignInWithAppleButton` est imposé par les règles de
//  présentation d'Apple : libellé, logo et proportions ne se redessinent pas.
//
//  Le nonce protège contre le rejeu : Apple reçoit son empreinte SHA-256, et
//  Supabase reçoit la valeur en clair pour vérifier qu'elle correspond à
//  l'empreinte signée dans le jeton.
//

import AuthenticationServices
import CryptoKit
import SwiftUI

struct AppleSignInButton: View {
    /// Appelé en cas d'échec, pour afficher le message dans l'écran parent.
    let onError: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Conservé entre la demande et la réponse d'Apple.
    @State private var rawNonce = ""
    @State private var isSigningIn = false

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            let nonce = Self.randomNonce()
            rawNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)
        } onCompletion: { result in
            handle(result)
        }
        // Noir sur fond clair, blanc sur fond sombre : la variante que les
        // règles d'Apple recommandent pour garder le contraste.
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 52)
        .clipShape(.capsule)
        .disabled(isSigningIn)
        .overlay {
            if isSigningIn {
                Capsule().fill(.black.opacity(0.35))
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .accessibilityHint("Connexion avec votre identifiant Apple")
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .failure(let error):
            // Fermer la fenêtre d'Apple n'est pas une erreur à signaler.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            onError(error.localizedDescription)
            Haptics.warning()

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else {
                onError("Apple n'a pas renvoyé d'identifiant exploitable. Réessaie.")
                return
            }

            isSigningIn = true
            Task {
                do {
                    try await AuthService.signInWithApple(
                        idToken: idToken,
                        rawNonce: rawNonce,
                        fullName: credential.fullName
                    )
                    Haptics.success()
                    // La bascule vers l'app est pilotée par `authStateChanges`,
                    // y compris le rattachement au club d'un nouveau compte.
                } catch {
                    onError(error.localizedDescription)
                    Haptics.warning()
                }
                isSigningIn = false
            }
        }
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator) ?? "0" })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
