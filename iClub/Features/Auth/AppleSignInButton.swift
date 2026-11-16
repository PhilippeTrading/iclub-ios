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
//  Rôle
//    Bouton de connexion par identifiant Apple, affiché en tête de l'écran de
//    connexion (`SignInView`). Il sert aussi d'inscription : un identifiant
//    Apple encore inconnu crée le compte Supabase à la première connexion.
//
//  Déroulé
//    1. Au tap, un nonce aléatoire est tiré et gardé en mémoire ; Apple en
//       reçoit l'empreinte SHA-256, avec la demande du nom et de l'e-mail.
//    2. Apple rend un jeton d'identité signé (JWT) ;
//       `AuthService.signInWithApple` l'échange contre une session Supabase
//       (`signInWithIdToken`, fournisseur Apple) en présentant le nonce en clair.
//    3. Le prénom et le nom, qu'Apple ne transmet qu'à la toute première
//       connexion, sont recopiés dans `profiles` s'ils y sont vides.
//    4. La suite est pilotée par `AuthController` (événement `signedIn`) :
//       lecture du profil, rattachement au club d'un nouveau compte
//       (`join_club_as_member`), puis écran de complétion, puisque Apple ne
//       fournit ni téléphone, ni date de naissance, ni sexe.
//
//  Erreurs
//    Remontées à l'écran parent par `onError`, déjà traduites par
//    `AuthService` (fournisseur Apple non activé dans Supabase, réseau...).
//    Fermer la fenêtre d'Apple n'est pas une erreur.
//
//  Droits et sécurité
//    Aucun secret dans l'app : la vérification du jeton et du nonce est faite
//    par Supabase Auth. Nécessite la capacité « Sign in with Apple »
//    (iClub.entitlements) et le fournisseur Apple activé dans Supabase.
//

import AuthenticationServices
import CryptoKit
import SwiftUI

/// Bouton officiel « Se connecter avec Apple », relié à Supabase Auth.
struct AppleSignInButton: View {
    /// Appelé en cas d'échec, pour afficher le message dans l'écran parent.
    /// Reçoit un message prêt à afficher.
    let onError: (String) -> Void

    /// Apparence claire ou sombre, pour choisir la variante du bouton.
    @Environment(\.colorScheme) private var colorScheme

    /// Conservé entre la demande et la réponse d'Apple.
    /// C'est la valeur en clair, transmise à Supabase après la réponse.
    @State private var rawNonce = ""
    /// Vrai pendant l'échange du jeton avec Supabase : bouton désactivé et
    /// voile d'attente.
    @State private var isSigningIn = false

    /// Le bouton officiel d'Apple, avec un voile d'attente pendant l'échange
    /// du jeton.
    var body: some View {
        // Préparation de la demande : nonce tiré, mémorisé en clair, et
        // transmis à Apple sous forme d'empreinte.
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
        // Voile sombre et roue d'attente pendant l'échange avec Supabase.
        .overlay {
            if isSigningIn {
                Capsule().fill(.black.opacity(0.35))
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .accessibilityHint("Connexion avec votre identifiant Apple")
    }

    /// Traite la réponse d'Apple : erreur à signaler, ou jeton à échanger
    /// contre une session Supabase.
    ///
    /// - Parameter result: autorisation Apple, ou erreur (annulation comprise).
    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .failure(let error):
            // Fermer la fenêtre d'Apple n'est pas une erreur à signaler.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            onError(error.localizedDescription)
            Haptics.warning()

        case .success(let authorization):
            // Le jeton d'identité arrive en octets : il doit être un texte
            // UTF-8 pour être transmis à Supabase.
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
                    // Échange du jeton contre une session, et recopie du nom
                    // transmis par Apple (première connexion seulement).
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

    /// Tire un nonce aléatoire.
    ///
    /// La source est `SystemRandomNumberGenerator`, le générateur
    /// cryptographique du système. Limite connue, sans conséquence pratique :
    /// le jeu de caractères ne contient pas la lettre « W » majuscule (63
    /// caractères au lieu de 64), ce qui laisse largement assez d'aléa pour
    /// 32 caractères.
    ///
    /// - Parameter length: nombre de caractères (32 par défaut).
    /// - Returns: le nonce en clair.
    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        // Le repli « 0 » ne sert jamais : le jeu de caractères n'est pas vide.
        return String((0..<length).map { _ in charset.randomElement(using: &generator) ?? "0" })
    }

    /// Empreinte SHA-256 d'un texte, en hexadécimal minuscule : la forme
    /// attendue par Apple dans `request.nonce`.
    ///
    /// - Parameter input: le nonce en clair.
    /// - Returns: 64 caractères hexadécimaux.
    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
