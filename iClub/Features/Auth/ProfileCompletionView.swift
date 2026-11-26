//
//  ProfileCompletionView.swift
//  iClub
//
//  « Compléter mon profil », présenté tant que le téléphone, la date de
//  naissance ou le sexe manquent.
//
//  C'est la pièce maîtresse de la connexion Google et Apple : ces fournisseurs
//  ne transmettent aucun des trois champs, or l'âge s'affiche sous chaque
//  joueur et le sexe conditionne la mixité des parties ouvertes.
//
//  Volontairement **sans bouton « plus tard »**. La seule sortie est la
//  déconnexion, pour qui se serait trompé de compte : elle ne laisse pas entrer
//  dans l'app avec un profil incomplet.
//

import SwiftUI

struct ProfileCompletionView: View {
    let profile: SessionProfile

    @Environment(AuthController.self) private var auth

    @State private var prenom: String
    @State private var nom: String
    @State private var telephone: String
    @State private var dateNaissance: Date
    @State private var sexe: Sexe?
    /// Un `DatePicker` ne peut pas être vide : il affiche toujours une date.
    /// Sans ce drapeau, valider sans y toucher enregistrerait la date par
    /// défaut — un âge inventé, affiché sous le nom du membre.
    @State private var hasChosenBirthDate: Bool

    @State private var hasLeftPhoneField = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(profile: SessionProfile) {
        self.profile = profile
        // Pré-rempli avec ce que le fournisseur a transmis (prénom et nom) et
        // ce que le profil contient déjà : on ne redemande jamais une
        // information connue.
        _prenom = State(initialValue: profile.prenom ?? "")
        _nom = State(initialValue: profile.nom)
        _telephone = State(initialValue: profile.formattedTelephone ?? "")
        _dateNaissance = State(initialValue: profile.dateNaissance
            ?? Calendar.current.date(byAdding: .year, value: -30, to: .now)
            ?? .now)
        _sexe = State(initialValue: profile.sexe)
        _hasChosenBirthDate = State(initialValue: profile.dateNaissance != nil)
    }

    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -110, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -4, to: .now) ?? .now
        return oldest...youngest
    }

    private var canSave: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && PhoneNumber.isValid(telephone)
            && hasChosenBirthDate
            && sexe != nil
            && !isSaving
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 14) {
                        fields
                        phoneHint

                        if let errorMessage {
                            InlineMessage(kind: .error, message: errorMessage)
                        }

                        PrimaryActionButton(
                            title: "Valider mon profil",
                            systemImage: "checkmark",
                            isLoading: isSaving
                        ) {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }

                Button("Ce n'est pas mon compte ? Se déconnecter") {
                    Task { await auth.signOut() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.textSecondary)
                .disabled(isSaving)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { AuroraBackground() }
        .animation(.smooth(duration: 0.3), value: errorMessage)
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(spacing: 8) {
            Text("Compléter mon profil")
                .font(.editorial(.largeTitle))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)

            // Un champ obligatoire dont on comprend l'usage est accepté ; un
            // champ obligatoire inexpliqué fait abandonner.
            Text("Votre âge et votre classement apparaissent sous votre nom dans les parties, et votre sexe permet de rejoindre les parties réservées aux hommes ou aux femmes.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Champs

    private var fields: some View {
        GlassFieldGroup {
            AuthField(kind: .firstName, systemImage: "person", placeholder: "Prénom", text: $prenom)
            FieldDivider()
            AuthField(kind: .lastName, systemImage: "person.text.rectangle", placeholder: "Nom", text: $nom)
            FieldDivider()
            AuthField(
                kind: .phone,
                systemImage: "phone",
                placeholder: "Téléphone",
                text: $telephone,
                onEditingEnd: { hasLeftPhoneField = true }
            )
            FieldDivider()
            GlassFieldRow(systemImage: "calendar") {
                DatePicker(
                    selection: $dateNaissance,
                    in: birthDateRange,
                    displayedComponents: .date
                ) {
                    // Grisé tant qu'aucune date n'a été choisie, comme le sexe.
                    Text("Date de naissance")
                        .foregroundStyle(hasChosenBirthDate ? .primary : .secondary)
                }
                .datePickerStyle(.compact)
                .font(.body)
                .onChange(of: dateNaissance) { hasChosenBirthDate = true }
            }
            FieldDivider()
            GlassFieldRow(systemImage: "figure.stand") {
                sexePicker
            }
        }
    }

    private var sexePicker: some View {
        HStack(spacing: 8) {
            Text("Sexe")
                .font(.body)
                .foregroundStyle(sexe == nil ? .secondary : .primary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Sexe.allCases) { option in
                    let isSelected = sexe == option
                    Button {
                        sexe = option
                        Haptics.selection()
                    } label: {
                        Text(option.rawValue)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .frame(width: 42, height: 32)
                            // Choisi : aplat bleu marine, très clair en mode
                            // sombre, d'où `textOnInverse` (voir BrandPalette).
                            .foregroundStyle(isSelected ? Brand.textOnInverse : Brand.textSecondary)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(isSelected ? Brand.navy700 : Brand.textSecondary.opacity(0.12))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    /// Même règle et même message qu'à l'inscription classique.
    private var phoneHint: some View {
        let isInvalid = hasLeftPhoneField && !PhoneNumber.isValid(telephone)

        return HStack(spacing: 6) {
            Image(systemName: isInvalid ? "exclamationmark.circle.fill" : "info.circle")
                .font(.caption2)
            Text(isInvalid ? PhoneNumber.errorMessage : PhoneNumber.hint)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(isInvalid ? Brand.error : Brand.textSecondary)
        .padding(.leading, 4)
    }

    // MARK: - Enregistrement

    private func save() {
        guard canSave, let sexe else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                // Même écriture que l'édition du profil : téléphone normalisé,
                // et contrôle qu'une ligne a bien été modifiée.
                try await ProfileService.updatePersonalInfo(
                    profileId: profile.id,
                    prenom: prenom,
                    nom: nom,
                    telephone: telephone,
                    dateNaissance: dateNaissance,
                    sexe: sexe
                )
                // Le rattachement au club a déjà eu lieu au chargement de la
                // session ; la relecture fait disparaître cet écran.
                await auth.refreshSessionProfile()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            isSaving = false
        }
    }
}

#Preview {
    // Cas typique d'une première connexion Google : prénom et nom transmis,
    // les trois champs indispensables vides.
    ProfileCompletionView(profile: SessionProfile(
        id: UUID(), clubMemberId: UUID(), email: "camille@gmail.com",
        nom: "Roux", prenom: "Camille", displayName: "Camille Roux",
        avatarUrl: nil, telephone: nil, dateNaissance: nil, sexe: nil,
        role: "membre", isAdmin: false, clubId: UUID(), clubName: "Club",
        classementTennis: nil, classementPadel: nil,
        hasActiveMembership: false, activeMembershipPeriod: nil, activeMembershipDetails: nil
    ))
    .environment(AuthController())
}
