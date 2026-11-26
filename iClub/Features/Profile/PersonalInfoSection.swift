//
//  PersonalInfoSection.swift
//  iClub
//
//  Informations personnelles du membre : lecture, puis édition sur place.
//
//  Le téléphone y est lisible et modifiable, avec exactement la même
//  validation qu'à l'inscription — la règle vit dans `PhoneNumber`, elle n'est
//  pas réécrite ici.
//

import SwiftUI

struct PersonalInfoSection: View {
    let profile: SessionProfile
    /// Rechargement du profil de session après écriture.
    let onSaved: () async -> Void

    @State private var isEditing = false
    @State private var prenom = ""
    @State private var nom = ""
    @State private var telephone = ""
    @State private var dateNaissance = Date.now
    @State private var sexe: Sexe?

    @State private var hasLeftPhoneField = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -110, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -4, to: .now) ?? .now
        return oldest...youngest
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if isEditing {
                    editor
                } else {
                    readOnly
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: isEditing)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            Text("Informations personnelles")
                .metaLabelStyle()

            Spacer(minLength: 0)

            if !isEditing {
                Button("Modifier") { beginEditing() }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.navy700)
            }
        }
    }

    // MARK: - Lecture

    private var readOnly: some View {
        VStack(spacing: 0) {
            row(systemImage: "person", label: "Nom", value: profile.displayName)
            Divider().opacity(0.4)
            row(systemImage: "envelope", label: "E-mail", value: profile.email)
            Divider().opacity(0.4)
            // « Non renseigné » plutôt qu'une ligne vide : le champ n'était pas
            // demandé avant, les comptes existants n'ont pas de numéro.
            row(
                systemImage: "phone",
                label: "Téléphone",
                value: profile.formattedTelephone ?? "Non renseigné",
                isMissing: profile.formattedTelephone == nil
            )
            Divider().opacity(0.4)
            row(
                systemImage: "calendar",
                label: "Date de naissance",
                value: profile.dateNaissance?.mediumFrenchDate ?? "Non renseignée",
                isMissing: profile.dateNaissance == nil
            )
            Divider().opacity(0.4)
            row(
                systemImage: "figure.stand",
                label: "Sexe",
                value: profile.sexe?.displayName ?? "Non renseigné",
                isMissing: profile.sexe == nil
            )
        }
    }

    private func row(
        systemImage: String,
        label: String,
        value: String,
        isMissing: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 22)

            Text(label)
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)

            Spacer(minLength: 12)

            // Une ligne, tronquée au milieu : une adresse e-mail ne se coupe
            // jamais en deux (« demoad-min »).
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(isMissing ? Brand.textSecondary : Brand.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }

    // MARK: - Édition

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        "Date de naissance",
                        selection: $dateNaissance,
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

            phoneHint

            if let errorMessage {
                InlineMessage(kind: .error, message: errorMessage)
            }

            HStack(spacing: 10) {
                Button("Annuler") { isEditing = false }
                    .buttonStyle(.glass)
                    .controlSize(.regular)

                Spacer(minLength: 0)

                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text("Enregistrer")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .tint(canSave ? Brand.navy700 : Brand.textSecondary.opacity(0.22))
                .disabled(!canSave)
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
                // « Femme » puis « Homme », comme le web.
                ForEach([Sexe.femme, Sexe.homme]) { option in
                    let isSelected = sexe == option
                    Button {
                        sexe = option
                        Haptics.selection()
                    } label: {
                        Text(option.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
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
            .animation(.snappy(duration: 0.25), value: sexe)
        }
    }

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
        .animation(.smooth(duration: 0.2), value: isInvalid)
    }

    // MARK: - Enregistrement

    private var canSave: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && PhoneNumber.isValid(telephone)
            && sexe != nil
            && !isSaving
    }

    private func beginEditing() {
        prenom = profile.prenom ?? ""
        nom = profile.nom
        // Le champ s'ouvre sur la version lisible ; c'est la version normalisée
        // qui repartira en base.
        telephone = profile.formattedTelephone ?? ""
        dateNaissance = profile.dateNaissance
            ?? Calendar.current.date(byAdding: .year, value: -30, to: .now)
            ?? .now
        sexe = profile.sexe
        hasLeftPhoneField = false
        errorMessage = nil
        isEditing = true
    }

    private func save() {
        guard canSave, let sexe else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await ProfileService.updatePersonalInfo(
                    profileId: profile.id,
                    prenom: prenom,
                    nom: nom,
                    telephone: telephone,
                    dateNaissance: dateNaissance,
                    sexe: sexe
                )
                await onSaved()
                Haptics.success()
                isSaving = false
                isEditing = false
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
                isSaving = false
            }
        }
    }
}
