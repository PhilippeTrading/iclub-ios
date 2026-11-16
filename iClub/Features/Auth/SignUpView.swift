//
//  SignUpView.swift
//  iClub
//
//  Inscription : mêmes champs que le web (prénom, nom, email, mot de passe +
//  confirmation stricte, date de naissance, sexe). Aucun champ « admin ».
//  Le compte créé n'a aucune adhésion tant qu'un administrateur ne lui en
//  attribue pas une.
//
//  Rôle
//    Écran « Créer un compte », poussé depuis l'écran de connexion
//    (`SignInView`). Il réunit prénom, nom, date de naissance, sexe, e-mail,
//    téléphone et mot de passe (avec confirmation), et crée le compte Supabase.
//
//  Données et services
//    La saisie vit dans un `SignUpDraft` (AuthService.swift), qui porte aussi
//    sa validation. `AuthController.signUp` → `AuthService.signUp` →
//    Supabase Auth `signUp`, avec prénom, nom, téléphone normalisé, date de
//    naissance et sexe dans les métadonnées de l'utilisateur. Le déclencheur
//    SQL `handle_new_user` (table `auth.users`) recopie ces métadonnées dans
//    `profiles`.
//
//  Règles métier
//    - Tous les champs sont obligatoires ; le téléphone doit être au format
//      français à 10 chiffres ou international (`PhoneNumber.isValid`) ;
//    - mot de passe d'au moins 8 caractères avec une majuscule et un chiffre,
//      identique à sa confirmation ;
//    - date de naissance entre 110 ans et 4 ans avant aujourd'hui.
//    Supabase applique de son côté ses propres règles de mot de passe (selon
//    la configuration du projet) et refuse une adresse déjà inscrite ; ses
//    refus sont traduits par `AuthService`.
//
//  Suite du parcours
//    - Si Supabase ouvre une session tout de suite, `AuthController` reçoit
//      l'événement de connexion : le compte, encore rattaché à aucun club, y
//      est inscrit comme simple adhérent (fonction SQL `join_club_as_member`,
//      qui fixe elle-même le rôle et l'absence de droits administrateur), puis
//      l'app s'ouvre.
//    - Sinon, l'écran demande de confirmer l'adresse depuis le courriel reçu,
//      puis de revenir se connecter.
//
//  Points d'attention
//    - Limite connue : la date de naissance est préremplie (30 ans avant
//      aujourd'hui, voir `SignUpDraft`) et rien ne vérifie que le membre l'a
//      modifiée ; une inscription peut donc partir avec cette date par défaut.
//    - La mention du règlement intérieur est informative : aucune
//      acceptation n'est enregistrée en base.
//

import SwiftUI

/// Formulaire d'inscription de l'espace membre, et écran d'attente de la
/// confirmation par e-mail.
struct SignUpView: View {
    /// Contrôleur de session : crée le compte.
    @Environment(AuthController.self) private var auth
    /// Retour à l'écran de connexion.
    @Environment(\.dismiss) private var dismiss

    /// Saisie en cours et ses règles de validation.
    @State private var draft = SignUpDraft()
    /// Message d'erreur affiché au-dessus du bouton, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Vrai pendant l'appel à Supabase Auth.
    @State private var isSubmitting = false
    /// Vrai quand Supabase attend la confirmation de l'adresse avant d'ouvrir
    /// une session : l'écran passe alors à l'état « Vérifie ta boîte mail ».
    @State private var awaitingEmailConfirmation = false
    /// Le téléphone n'est validé qu'une fois le champ quitté : valider à chaque
    /// frappe ferait clignoter le message pendant la saisie.
    @State private var hasLeftPhoneField = false

    /// Bornes raisonnables pour la date de naissance.
    /// De 110 ans à 4 ans avant aujourd'hui, calculées à chaque affichage.
    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -110, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -4, to: .now) ?? .now
        return oldest...youngest
    }

    /// Le formulaire, ou l'attente de confirmation par e-mail, sur le fond en
    /// dégradé.
    var body: some View {
        ScrollView {
            // Attente de confirmation une fois l'inscription envoyée, sinon le
            // formulaire.
            if awaitingEmailConfirmation {
                confirmationState
            } else {
                form
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background { AuroraBackground() }
        .navigationTitle("Créer un compte")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth(duration: 0.35), value: awaitingEmailConfirmation)
        .animation(.smooth(duration: 0.3), value: errorMessage)
    }

    // MARK: - Formulaire

    /// Le formulaire complet : titre, identité, connexion, erreur, bouton et
    /// mention du règlement.
    private var form: some View {
        VStack(spacing: 24) {
            // Titre et rappel : l'adhésion est activée par le secrétariat.
            VStack(spacing: 6) {
                Text("Rejoins le club")
                    .font(.editorial(.largeTitle))
                    .foregroundStyle(Brand.navy800)
                Text("Crée ton compte : ton adhésion sera activée par le secrétariat.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 14) {
                    identityGroup
                    credentialsGroup

                    // Erreur renvoyée par Supabase (adresse déjà utilisée,
                    // mot de passe refusé, réseau...).
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }

                    // Actif seulement quand toute la saisie est valide.
                    PrimaryActionButton(
                        title: "Créer mon compte",
                        systemImage: "checkmark",
                        isLoading: isSubmitting
                    ) {
                        submit()
                    }
                    .disabled(!draft.isValid || isSubmitting)
                }
            }

            Text("En créant un compte, tu acceptes le règlement intérieur du club.")
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        // Colonne bornée à 480 points et centrée.
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    /// Bloc « Identité » : prénom, nom, date de naissance et sexe.
    private var identityGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identité")
                .metaLabelStyle()
                .padding(.leading, 4)

            GlassFieldGroup {
                AuthField(
                    kind: .firstName,
                    systemImage: "person",
                    placeholder: "Prénom",
                    text: $draft.prenom
                )
                FieldDivider()
                AuthField(
                    kind: .lastName,
                    systemImage: "person.text.rectangle",
                    placeholder: "Nom",
                    text: $draft.nom
                )
                FieldDivider()
                // Date de naissance, limitée à `birthDateRange`.
                GlassFieldRow(systemImage: "calendar") {
                    DatePicker(
                        "Date de naissance",
                        selection: $draft.dateNaissance,
                        in: birthDateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .font(.body)
                }
                FieldDivider()
                GlassFieldRow(systemImage: "figure.stand") {
                    sexePicker
                }
            }
        }
    }

    /// Choix du sexe par deux pastilles « H » et « F » (valeurs de
    /// `profiles.sexe`), lues « Homme » et « Femme » par VoiceOver. Aucun choix
    /// n'est fait par défaut : le libellé reste grisé tant qu'il manque.
    private var sexePicker: some View {
        HStack(spacing: 8) {
            Text("Sexe")
                .font(.body)
                .foregroundStyle(draft.sexe == nil ? .secondary : .primary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Sexe.allCases) { option in
                    let isSelected = draft.sexe == option
                    Button {
                        draft.sexe = option
                        Haptics.selection()
                    } label: {
                        Text(option.rawValue)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .frame(width: 42, height: 32)
                            .foregroundStyle(isSelected ? Color.white : Brand.textSecondary)
                            // Pastille pleine pour l'option choisie, teintée
                            // pour l'autre.
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(Brand.navy700)
                                } else {
                                    Capsule(style: .continuous)
                                        .fill(Brand.textSecondary.opacity(0.12))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .animation(.snappy(duration: 0.25), value: draft.sexe)
        }
    }

    /// Bloc « Connexion » : e-mail, téléphone, mot de passe et confirmation,
    /// suivis des indications sur le téléphone et le mot de passe.
    private var credentialsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connexion")
                .metaLabelStyle()
                .padding(.leading, 4)

            GlassFieldGroup {
                AuthField(
                    kind: .email,
                    systemImage: "envelope",
                    placeholder: "Adresse email",
                    text: $draft.email
                )
                FieldDivider()
                // Le format n'est contrôlé qu'à la sortie du champ.
                AuthField(
                    kind: .phone,
                    systemImage: "phone",
                    placeholder: "Téléphone",
                    text: $draft.telephone,
                    onEditingEnd: { hasLeftPhoneField = true }
                )
                FieldDivider()
                AuthField(
                    kind: .newPassword,
                    systemImage: "lock",
                    placeholder: "Mot de passe",
                    text: $draft.password
                )
                FieldDivider()
                AuthField(
                    kind: .newPassword,
                    systemImage: "lock.rotation",
                    placeholder: "Confirmer le mot de passe",
                    text: $draft.confirmPassword
                )
            }

            phoneHint
            passwordHints
        }
    }

    /// Indication en gris, qui passe en rouge une fois le champ quitté si le
    /// format ne convient pas.
    private var phoneHint: some View {
        let isInvalid = hasLeftPhoneField && !draft.isTelephoneValid

        return HStack(spacing: 6) {
            Image(systemName: isInvalid ? "exclamationmark.circle.fill" : "info.circle")
                .font(.caption2)
            Text(isInvalid ? PhoneNumber.errorMessage : PhoneNumber.hint)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(isInvalid ? Brand.error : Brand.textSecondary)
        .padding(.leading, 4)
        .animation(.smooth(duration: 0.2), value: isInvalid)
    }

    /// Règles du mot de passe et correspondance avec la confirmation, cochées
    /// en vert au fur et à mesure qu'elles sont respectées.
    @ViewBuilder
    private var passwordHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Les trois règles ne s'affichent que si l'une d'elles manque :
            // inutile d'encombrer l'écran quand le mot de passe convient.
            if !draft.password.isEmpty && !draft.isPasswordStrong {
                hint(
                    "Au moins \(SignUpDraft.minimumPasswordLength) caractères",
                    isSatisfied: draft.isPasswordLongEnough
                )
                hint("Au moins une majuscule", isSatisfied: draft.hasUppercase)
                hint("Au moins un chiffre", isSatisfied: draft.hasDigit)
            }
            // Correspondance, dès que la confirmation est commencée.
            if !draft.confirmPassword.isEmpty {
                hint(
                    draft.passwordsMatch
                        ? "Les mots de passe correspondent"
                        : "Les mots de passe ne correspondent pas",
                    isSatisfied: draft.passwordsMatch
                )
            }
        }
        .padding(.leading, 4)
        .animation(.smooth(duration: 0.2), value: draft.passwordsMatch)
        .animation(.smooth(duration: 0.2), value: draft.isPasswordStrong)
    }

    /// Une ligne d'indication : rond vide en gris, ou coche verte quand la
    /// règle est respectée.
    ///
    /// - Parameters:
    ///   - text: libellé de la règle.
    ///   - isSatisfied: vrai si la saisie respecte la règle.
    /// - Returns: la ligne à afficher.
    private func hint(_ text: String, isSatisfied: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(isSatisfied ? Brand.success : Brand.textSecondary)
    }

    // MARK: - Confirmation par email

    /// État affiché quand Supabase attend la confirmation de l'adresse : le
    /// compte existe, mais aucune session n'est ouverte avant le clic sur le
    /// lien reçu.
    private var confirmationState: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.primary)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)

            Text("Vérifie ta boîte mail")
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)

            Text("Nous avons envoyé un lien de confirmation à \(draft.trimmedEmail). Clique dessus pour activer ton compte, puis reviens te connecter.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            // Revient à l'écran de connexion.
            SecondaryActionButton(title: "Retour à la connexion", systemImage: "chevron.left") {
                dismiss()
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Soumission

    /// Crée le compte. Selon la réponse de Supabase, l'app s'ouvre (session
    /// immédiate) ou l'écran passe à l'attente de confirmation ; en cas
    /// d'échec, le message traduit s'affiche.
    private func submit() {
        guard draft.isValid, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                // `true` si Supabase a ouvert une session tout de suite.
                let sessionOpened = try await auth.signUp(draft)
                Haptics.success()
                if !sessionOpened {
                    awaitingEmailConfirmation = true
                }
                // Si une session a été ouverte, `authStateChanges` bascule l'app.
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            isSubmitting = false
        }
    }
}

/// Aperçu Xcode du formulaire, en français.
#Preview {
    NavigationStack {
        SignUpView()
    }
    .environment(AuthController())
    .environment(\.locale, AppLocale.french)
}
