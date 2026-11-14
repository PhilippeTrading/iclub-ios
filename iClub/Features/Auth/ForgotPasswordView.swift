//
//  ForgotPasswordView.swift
//  iClub
//
//  Flux standard Supabase : envoi d'un email de réinitialisation.
//
//  Rôle
//    Feuille « Mot de passe oublié », ouverte depuis l'écran de connexion
//    (`SignInView`) en demi-hauteur, avec l'e-mail déjà saisi. Le membre
//    confirme son adresse et reçoit un lien pour choisir un nouveau mot de
//    passe.
//
//  Données et services
//    `AuthController.sendPasswordReset` → `AuthService.sendPasswordReset` →
//    Supabase Auth `resetPasswordForEmail`, avec l'adresse de retour
//    `AppConfiguration.passwordResetRedirect` (`iclub://reset-password`).
//    Aucune table n'est lue ni écrite par l'app.
//
//  États
//    Formulaire (bouton inactif tant que l'adresse est vide, roue pendant
//    l'envoi, erreur en ligne), puis confirmation « Lien envoyé ».
//
//  Droits et sécurité
//    La confirmation est formulée au conditionnel (« si un compte existe ») :
//    l'écran ne révèle pas si l'adresse a un compte.
//
//  Points d'attention
//    Attention : l'application ne déclare pas le schéma d'URL `iclub` dans ses
//    réglages (Info.plist généré) et ne traite pas ce lien de retour : le choix
//    du nouveau mot de passe ne peut donc pas se faire dans l'app. Si
//    l'adresse `iclub://reset-password` n'est pas autorisée dans Supabase
//    (Authentication, URL Configuration), Supabase renvoie vers l'adresse du
//    site configurée par défaut.
//

import SwiftUI

/// Feuille d'envoi du lien de réinitialisation du mot de passe.
struct ForgotPasswordView: View {
    /// Adresse déjà saisie sur l'écran de connexion, recopiée dans le champ à
    /// l'ouverture (chaîne vide si rien n'avait été saisi).
    let prefilledEmail: String

    /// Contrôleur de session : envoie la demande à Supabase Auth.
    @Environment(AuthController.self) private var auth
    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Adresse saisie dans la feuille.
    @State private var email = ""
    /// Vrai pendant l'envoi de la demande.
    @State private var isSubmitting = false
    /// Message d'erreur affiché sous le champ, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Vrai une fois la demande acceptée : l'écran passe à la confirmation.
    @State private var didSend = false

    /// Bouton actif dès qu'une adresse non vide est saisie et qu'aucun envoi
    /// n'est en cours. Le format de l'adresse n'est pas contrôlé ici.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    /// Feuille avec sa propre barre de titre : formulaire, puis confirmation.
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Confirmation une fois le lien envoyé, formulaire sinon.
                if didSend {
                    sentState
                } else {
                    form
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Mot de passe oublié")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Fermeture sans rien envoyer.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.3), value: didSend)
            .animation(.smooth(duration: 0.3), value: errorMessage)
        }
        // L'adresse de l'écran de connexion est reprise à chaque ouverture.
        .onAppear { email = prefilledEmail }
    }

    /// Formulaire : explication, champ e-mail, erreur éventuelle et bouton
    /// « Envoyer le lien ».
    private var form: some View {
        VStack(spacing: 16) {
            Text("Indique ton adresse email : tu recevras un lien pour choisir un nouveau mot de passe.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 14) {
                    // Champ unique : l'adresse e-mail.
                    GlassFieldGroup {
                        AuthField(
                            kind: .email,
                            systemImage: "envelope",
                            placeholder: "Adresse email",
                            text: $email
                        )
                    }

                    // Erreur de la dernière tentative (réseau, trop de
                    // demandes...), déjà traduite par `AuthService`.
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }

                    PrimaryActionButton(
                        title: "Envoyer le lien",
                        systemImage: "paperplane.fill",
                        isLoading: isSubmitting
                    ) {
                        submit()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    /// Confirmation d'envoi : rappelle l'adresse (en minuscules, comme elle a
    /// été envoyée) et invite à vérifier les courriers indésirables.
    private var sentState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Brand.success)
                .padding(.top, 12)

            Text("Lien envoyé")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)

            Text("Si un compte existe pour \(email.lowercased()), un email vient de partir. Pense à regarder tes indésirables.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            SecondaryActionButton(title: "Terminé") { dismiss() }
                .padding(.top, 4)
        }
    }

    /// Demande à Supabase l'envoi du courriel de réinitialisation. Succès :
    /// passage à la confirmation. Échec : message sous le champ.
    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await auth.sendPasswordReset(to: email)
                didSend = true
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            isSubmitting = false
        }
    }
}

/// Aperçu Xcode, avec une adresse d'exemple.
#Preview {
    ForgotPasswordView(prefilledEmail: "camille@example.com")
        .environment(AuthController())
}
