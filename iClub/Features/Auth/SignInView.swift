//
//  SignInView.swift
//  iClub
//
//  Rôle
//    Écran de connexion de l'espace membre. C'est l'écran affiché par
//    `RootView` quand personne n'est connecté (phase `.signedOut`), dans sa
//    propre `NavigationStack`.
//
//  Contenu, de haut en bas
//    - logo et titre d'accueil ;
//    - « Se connecter avec Apple » (`AppleSignInButton`), en premier car c'est
//      la voie la plus rapide ; « Continuer avec Google », en sommeil ;
//    - e-mail et mot de passe, avec le bouton « Se connecter » ;
//    - « Mot de passe oublié ? », qui ouvre `ForgotPasswordView` en feuille ;
//    - « Créer un compte », qui pousse `SignUpView`.
//
//  Données et services
//    La connexion par e-mail passe par `AuthController.signIn`, puis
//    `AuthService.signIn` (Supabase Auth, mot de passe). Aucune donnée de club
//    n'est lue ici : après une connexion réussie, `AuthController` reçoit
//    l'événement `signedIn`, charge le profil et `RootView` bascule d'écran.
//
//  États
//    Bouton désactivé tant que l'e-mail ou le mot de passe est vide, roue
//    d'attente pendant l'envoi, message d'erreur en ligne (identifiants
//    incorrects, e-mail non confirmé, trop de tentatives, réseau...), déjà
//    traduit par `AuthService`.
//
//  Points d'attention
//    Un compte créé avec Apple n'a pas de mot de passe : il ne peut pas encore
//    se connecter sur le site web du club, ce que l'écran annonce.
//

import SwiftUI

/// Écran de connexion : Apple, e-mail et mot de passe, mot de passe oublié,
/// création de compte.
struct SignInView: View {
    /// Contrôleur de session : envoie la demande de connexion.
    @Environment(AuthController.self) private var auth

    /// Adresse saisie. Elle est aussi transmise à l'écran du mot de passe
    /// oublié, pour éviter de la retaper.
    @State private var email = ""
    /// Mot de passe saisi, jamais conservé ailleurs que dans cet état.
    @State private var password = ""
    /// Message d'erreur affiché sous les champs, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Vrai pendant l'appel à Supabase Auth.
    @State private var isSubmitting = false
    /// Vrai pendant que la feuille « Mot de passe oublié » est ouverte.
    @State private var showForgotPassword = false

    /// Le bouton « Se connecter » n'est actif qu'avec un e-mail non vide (hors
    /// espaces), un mot de passe non vide, et aucun envoi en cours. Le format
    /// de l'e-mail n'est pas vérifié ici : Supabase répond « identifiants
    /// incorrects » le cas échéant.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    /// Colonne défilante sur le fond en dégradé, de haut en bas : logo,
    /// accueil, Apple, e-mail et mot de passe, mot de passe oublié, création
    /// de compte.
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                // Logo de l'application.
                BrandMark()
                    .padding(.top, 24)

                // Titre d'accueil et promesse de l'espace membre.
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

                    // EN SOMMEIL, volontairement : ne pas supprimer.
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

                // Connexion par e-mail et mot de passe.
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 14) {
                        // Les deux champs, sur un même panneau de verre.
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

                        // Erreur de la dernière tentative (connexion ou Apple).
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

                // Lien vers la réinitialisation du mot de passe.
                Button("Mot de passe oublié ?") {
                    showForgotPassword = true
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.navy700)

                separator

                // Création de compte, poussée dans la pile de l'écran.
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
            // Colonne bornée à 480 points et centrée (iPad, paysage).
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { AuroraBackground() }
        // Apparition et disparition du message d'erreur animées.
        .animation(.smooth(duration: 0.3), value: errorMessage)
        // Mot de passe oublié, en demi-feuille, avec l'e-mail déjà saisi.
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView(prefilledEmail: email)
                .presentationDetents([.medium])
                .presentationCornerRadius(Radius.card)
        }
    }

    /// Séparateur horizontal « ou » entre deux façons de se connecter.
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

    /// Envoie la demande de connexion par e-mail et mot de passe.
    ///
    /// En cas de succès, rien à faire ici : `AuthController` reçoit
    /// l'événement de connexion et `RootView` change d'écran. En cas d'échec,
    /// le message traduit par `AuthService` s'affiche sous les champs.
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

/// Aperçu Xcode de l'écran de connexion.
#Preview {
    NavigationStack {
        SignInView()
    }
    .environment(AuthController())
}
