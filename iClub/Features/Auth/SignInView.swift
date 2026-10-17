//
//  SignInView.swift
//  iClub
//

import SwiftUI

struct SignInView: View {
    @Environment(AuthController.self) private var auth

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var showForgotPassword = false

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                BrandMark()
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text("Bon retour")
                        .font(.editorial(.largeTitle))
                        .foregroundStyle(Brand.navy800)
                    Text("Connecte-toi pour réserver et rejoindre des parties.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // En tête du formulaire, avant l'e-mail : c'est la voie la
                // plus rapide, elle doit être le premier choix visible.
                VStack(spacing: 12) {
                    AppleSignInButton { message in
                        errorMessage = message
                    }

                    // EN SOMMEIL, volontairement — ne pas supprimer.
                    // La connexion Google est repoussée (décision produit). Ce
                    // bloc ne s'affiche pas tant que le paquet GoogleSignIn-iOS
                    // n'est pas dans le projet, et s'activera de lui-même quand
                    // il le sera. Il faudra alors configurer le fournisseur
                    // Google côté Supabase : voir `AuthService.signInWithGoogle`.
                    if AuthService.isGoogleSignInAvailable {
                        GoogleSignInButtonView { message in
                            errorMessage = message
                        }
                    }

                    // Le site du club ne propose pas la connexion Apple : un
                    // compte créé ainsi n'y a pas de mot de passe. On le dit
                    // avant, plutôt que de le laisser découvrir.
                    // Le jour où Google est réactivé, citer aussi Google ici.
                    Text("Un compte créé avec Apple ne permet pas encore de se connecter sur le site du club.")
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)

                    separator
                        .padding(.top, 6)
                }

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 14) {
                        GlassFieldGroup {
                            AuthField(
                                kind: .email,
                                systemImage: "envelope",
                                placeholder: "Adresse email",
                                text: $email
                            )
                            FieldDivider()
                            AuthField(
                                kind: .currentPassword,
                                systemImage: "lock",
                                placeholder: "Mot de passe",
                                text: $password
                            )
                        }

                        if let errorMessage {
                            InlineMessage(kind: .error, message: errorMessage)
                        }

                        PrimaryActionButton(
                            title: "Se connecter",
                            systemImage: "arrow.right",
                            isLoading: isSubmitting
                        ) {
                            submit()
                        }
                        .disabled(!canSubmit)
                    }
                }

                Button("Mot de passe oublié ?") {
                    showForgotPassword = true
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.navy700)

                separator

                VStack(spacing: 10) {
                    Text("Nouveau au club ?")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)

                    NavigationLink {
                        SignUpView()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Créer un compte")
                                .font(.system(.headline, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { AuroraBackground() }
        .animation(.smooth(duration: 0.3), value: errorMessage)
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView(prefilledEmail: email)
                .presentationDetents([.medium])
                .presentationCornerRadius(Radius.card)
        }
    }

    private var separator: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Brand.hairline)
                .frame(height: 1)
            Text("ou")
                .metaLabelStyle()
            Rectangle()
                .fill(Brand.hairline)
                .frame(height: 1)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await auth.signIn(email: email, password: password)
                Haptics.success()
                // La bascule vers l'app est pilotée par `authStateChanges`.
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            isSubmitting = false
        }
    }
}

#Preview {
    NavigationStack {
        SignInView()
    }
    .environment(AuthController())
}
