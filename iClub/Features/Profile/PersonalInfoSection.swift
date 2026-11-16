//
//  PersonalInfoSection.swift
//  iClub
//
//  Rôle
//    Informations personnelles du membre : lecture, puis édition sur place.
//
//    Le téléphone y est lisible et modifiable, avec exactement la même
//    validation qu'à l'inscription : la règle vit dans `PhoneNumber`, elle
//    n'est pas réécrite ici.
//
//  Place dans l'application
//    Carte de l'onglet Profil (ProfileView), pour le compte connecté
//    uniquement (jamais pour un enfant).
//
//  Données et écriture
//    Lecture : le profil de session. Écriture : ProfileService
//    .updatePersonalInfo met à jour la ligne `profiles` du membre (prénom et
//    nom sans blancs autour, téléphone normalisé, date de naissance, sexe en
//    H ou F) ; la RLS ne laisse modifier que sa propre ligne, et une écriture
//    qui ne touche aucune ligne est traitée comme un refus. L'adresse e-mail
//    n'est pas modifiable ici.
//
//  Règles de saisie
//    Prénom et nom non vides, téléphone valide (10 chiffres commençant par 0,
//    ou « + » suivi de 8 à 15 chiffres), sexe choisi ; date de naissance entre
//    110 et 4 ans avant aujourd'hui. Ces trois données (téléphone, date de
//    naissance, sexe) sont celles qu'exige un profil complet
//    (SessionProfile.isComplete).
//

import SwiftUI

/// Carte « Informations personnelles », en lecture ou en édition.
struct PersonalInfoSection: View {
    /// Le compte connecté.
    let profile: SessionProfile
    /// Rechargement du profil de session après écriture.
    let onSaved: () async -> Void

    /// Mode édition ouvert.
    @State private var isEditing = false
    /// Prénom en cours d'édition.
    @State private var prenom = ""
    /// Nom en cours d'édition.
    @State private var nom = ""
    /// Téléphone en cours d'édition (tel que saisi, normalisé à l'envoi).
    @State private var telephone = ""
    /// Date de naissance en cours d'édition.
    @State private var dateNaissance = Date.now
    /// Sexe en cours d'édition ; `nil` tant qu'il n'est pas choisi.
    @State private var sexe: Sexe?

    /// Le champ téléphone a été quitté une fois : l'erreur de format peut
    /// s'afficher.
    @State private var hasLeftPhoneField = false
    /// Enregistrement en cours.
    @State private var isSaving = false
    /// Message d'échec de l'enregistrement.
    @State private var errorMessage: String?

    /// Dates de naissance admises : de 110 ans à 4 ans avant aujourd'hui.
    private var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .year, value: -110, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -4, to: .now) ?? .now
        return oldest...youngest
    }

    /// En-tête, puis la lecture ou le formulaire, avec une transition douce
    /// entre les deux.
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

    /// Titre de la carte et bouton « Modifier » (masqué pendant l'édition).
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

    /// Les cinq lignes en lecture : nom, e-mail, téléphone, date de naissance,
    /// sexe ; une valeur absente s'affiche en gris.
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

    /// Une ligne de lecture : icône, intitulé, valeur à droite.
    /// - Parameters:
    ///   - systemImage: symbole SF Symbols.
    ///   - label: intitulé.
    ///   - value: valeur affichée.
    ///   - isMissing: valeur absente (affichée en gris).
    /// - Returns: la ligne, lue d'un bloc par VoiceOver (« intitulé : valeur »).
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

    /// Le formulaire : prénom, nom, téléphone, date de naissance, sexe, puis
    /// l'aide sur le téléphone, l'erreur éventuelle et les boutons.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassFieldGroup {
                AuthField(kind: .firstName, systemImage: "person", placeholder: "Prénom", text: $prenom)
                FieldDivider()
                AuthField(kind: .lastName, systemImage: "person.text.rectangle", placeholder: "Nom", text: $nom)
                FieldDivider()
                // Le format n'est jugé qu'une fois le champ quitté.
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

            // « Annuler » abandonne la saisie (rien n'est écrit) ;
            // « Enregistrer », grisé tant que la saisie n'est pas valide.
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

    /// Choix du sexe en deux pastilles, « Femme » et « Homme » ; l'intitulé
    /// reste gris tant que rien n'est choisi.
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
                            .foregroundStyle(isSelected ? Color.white : Brand.textSecondary)
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

    /// Aide sous le formulaire : le format attendu en gris, ou le message
    /// d'erreur en rouge si le champ quitté contient un numéro invalide.
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

    /// Enregistrement permis : prénom et nom non vides, téléphone valide, sexe
    /// choisi, aucun envoi en cours.
    private var canSave: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && PhoneNumber.isValid(telephone)
            && sexe != nil
            && !isSaving
    }

    /// Ouvre l'édition, préremplie avec le profil actuel.
    private func beginEditing() {
        prenom = profile.prenom ?? ""
        nom = profile.nom
        // Le champ s'ouvre sur la version lisible ; c'est la version normalisée
        // qui repartira en base.
        telephone = profile.formattedTelephone ?? ""
        // Date inconnue : le sélecteur part de 30 ans avant aujourd'hui.
        dateNaissance = profile.dateNaissance
            ?? Calendar.current.date(byAdding: .year, value: -30, to: .now)
            ?? .now
        sexe = profile.sexe
        hasLeftPhoneField = false
        errorMessage = nil
        isEditing = true
    }

    /// Écrit les informations, relit le profil de session, puis referme
    /// l'édition ; en cas d'échec, le formulaire reste ouvert avec le message.
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
