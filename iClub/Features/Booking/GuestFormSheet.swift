//
//  GuestFormSheet.swift
//  iClub
//
//  Ajout d'un invité non-membre : prénom, nom, et qui règle sa part.
//
//  Les deux champs sont obligatoires, avec un message sur le champ vide plutôt
//  qu'un bouton inerte sans explication.
//
//  Place dans l'application
//    Feuille ouverte par le bouton « Invité » de l'écran des joueurs
//    (`ParticipantsView`). Elle ne lit ni n'écrit rien en base : l'invité est
//    ajouté au brouillon (`BookingDraft`), et n'est enregistré qu'à la
//    confirmation, comme ligne `reservation_participants` de type « invite »
//    sans profil.
//
//  Règles
//    - Crédit invité : gratuit, possible seulement s'il reste des crédits sur
//      la période d'adhésion du réservataire (panier en cours déduit).
//    - Supplément : `BookingPricing.guestSupplement` (10 €), ajouté au total à
//      régler.
//    Ces règles ne sont appliquées que par l'app : la base ne contrôle ni le
//    solde de crédits ni le montant du supplément.
//

import SwiftUI

/// Formulaire d'un invité : identité et mode de prise en charge de sa part.
struct GuestFormSheet: View {
    /// Crédits encore disponibles, panier en cours déduit.
    let creditsRemaining: Int
    /// Appelé avec le prénom et le nom nettoyés (espaces de bord retirés) et le
    /// mode de prise en charge choisi, juste avant la fermeture.
    let onAdd: (_ prenom: String, _ nom: String, _ payer: GuestPayer) -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Prénom saisi.
    @State private var prenom = ""
    /// Nom saisi.
    @State private var nom = ""
    /// Prise en charge choisie ; réglée à l'ouverture selon les crédits.
    @State private var payer: GuestPayer = .supplement
    /// Vrai après un premier appui sur « Ajouter » : les erreurs de saisie ne
    /// s'affichent qu'à partir de là.
    @State private var hasSubmitted = false

    /// Vrai s'il reste au moins un crédit invité.
    private var hasCredit: Bool { creditsRemaining > 0 }

    /// Prénom sans espaces de début et de fin.
    private var trimmedPrenom: String { prenom.trimmingCharacters(in: .whitespaces) }
    /// Nom sans espaces de début et de fin.
    private var trimmedNom: String { nom.trimmingCharacters(in: .whitespaces) }

    /// Feuille avec sa barre de titre : identité, prise en charge, bouton
    /// « Ajouter l'invité ».
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityFields
                    payerPicker

                    // Toujours actif : un appui avec un champ vide affiche
                    // l'erreur au lieu de laisser un bouton inerte.
                    PrimaryActionButton(title: "Ajouter l'invité", systemImage: "person.badge.plus") {
                        submit()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Ajouter un invité")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Fermeture sans rien ajouter.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .onAppear {
                // Le crédit est présélectionné s'il en reste, sinon le supplément.
                payer = hasCredit ? .credit : .supplement
            }
        }
    }

    // MARK: - Identité

    /// Prénom et nom de l'invité, et le message d'erreur après un essai.
    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassFieldGroup {
                AuthField(kind: .firstName, systemImage: "person", placeholder: "Prénom", text: $prenom)
                FieldDivider()
                AuthField(kind: .lastName, systemImage: "textformat", placeholder: "Nom", text: $nom)
            }

            // Erreur de saisie, seulement après un appui sur « Ajouter ».
            if hasSubmitted, let message = validationMessage {
                InlineMessage(kind: .error, message: message)
            }
        }
    }

    /// Message adapté au champ manquant, ou `nil` si la saisie est complète.
    private var validationMessage: String? {
        if trimmedPrenom.isEmpty, trimmedNom.isEmpty { return "Renseigne le prénom et le nom de l'invité." }
        if trimmedPrenom.isEmpty { return "Le prénom de l'invité est obligatoire." }
        if trimmedNom.isEmpty { return "Le nom de l'invité est obligatoire." }
        return nil
    }

    // MARK: - Qui paie

    /// Les deux prises en charge possibles : crédit invité (grisé s'il n'en
    /// reste pas) ou supplément.
    private var payerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Qui paie l'invité ?")
                .metaLabelStyle()

            VStack(spacing: 8) {
                // « Gratuit · 2 restants », ou « Crédit invité épuisé ».
                payerOption(
                    .credit,
                    title: "Crédit invité",
                    detail: hasCredit
                        ? "Gratuit · \(creditsRemaining) restant\(creditsRemaining > 1 ? "s" : "")"
                        : "Crédit invité épuisé",
                    systemImage: "ticket",
                    isEnabled: hasCredit
                )

                // « 10,00 € à régler », toujours possible.
                payerOption(
                    .supplement,
                    title: "Payer le supplément",
                    detail: "\(Price.amount(BookingPricing.guestSupplement)) à régler",
                    systemImage: "creditcard",
                    isEnabled: true
                )
            }
        }
    }

    /// Une option de prise en charge, présentée comme un bouton radio.
    ///
    /// - Parameters:
    ///   - value: prise en charge choisie par l'option.
    ///   - title: intitulé de l'option.
    ///   - detail: précision sous l'intitulé (gratuit, montant, épuisé).
    ///   - systemImage: pictogramme de l'option.
    ///   - isEnabled: faux pour une option impossible, grisée et inactive.
    /// - Returns: le bouton de l'option.
    private func payerOption(
        _ value: GuestPayer,
        title: String,
        detail: String,
        systemImage: String,
        isEnabled: Bool
    ) -> some View {
        let isSelected = payer == value

        return Button {
            payer = value
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isEnabled ? Brand.navy700 : Brand.textSecondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(isEnabled ? Brand.textPrimary : Brand.textSecondary)
                    // Le détail passe en orange quand l'option est impossible.
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isEnabled ? Brand.textSecondary : Brand.warning)
                }

                Spacer(minLength: 0)

                // Rond plein pour l'option choisie.
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? Brand.navy700 : Brand.hairline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: Radius.inner)
            .opacity(isEnabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Validation

    /// Valide la saisie ; si elle est complète, transmet l'invité au brouillon
    /// et ferme la feuille, sinon affiche l'erreur avec une vibration
    /// d'avertissement.
    private func submit() {
        hasSubmitted = true
        guard validationMessage == nil else {
            Haptics.warning()
            return
        }

        onAdd(trimmedPrenom, trimmedNom, payer)
        Haptics.selection()
        dismiss()
    }
}
