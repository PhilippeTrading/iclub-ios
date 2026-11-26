//
//  SignUpView.swift
//  iClub
//
//  Inscription : mêmes champs que le web (prénom, nom, email, mot de passe +
//  confirmation stricte, date de naissance, sexe). Aucun champ « admin ».
//  Le compte créé n'a aucune adhésion tant qu'un administrateur ne lui en
//  attribue pas une.
//

import SwiftUI

struct SignUpView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SignUpDraft()
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var awaitingEmailConfirmation = false
    /// Le téléphone n'est validé qu'une fois le champ quitté : valider à chaque
    /// frappe ferait clignoter le message pendant la saisie.
    @State private var hasLeftPhoneField = false

    /// Bornes raisonnables pour la date de naissance.
    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -110, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -4, to: .now) ?? .now
        return oldest...youngest
    }

    var body: some View {
        ScrollView {
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

    private var form: some View {
        VStack(spacing: 24) {
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

                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }

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
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

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
                            // Choisi : aplat bleu marine, très clair en mode
                            // sombre, d'où `textOnInverse` (voir BrandPalette).
                            .foregroundStyle(isSelected ? Brand.textOnInverse : Brand.textSecondary)
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

    private func submit() {
        guard draft.isValid, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
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

#Preview {
    NavigationStack {
        SignUpView()
    }
    .environment(AuthController())
    .environment(\.locale, AppLocale.french)
}
