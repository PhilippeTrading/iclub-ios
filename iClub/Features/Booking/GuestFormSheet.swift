//
//  GuestFormSheet.swift
//  iClub
//
//  Ajout d'un invité non-membre : prénom, nom, et qui règle sa part.
//
//  Les deux champs sont obligatoires, avec un message sur le champ vide plutôt
//  qu'un bouton inerte sans explication.
//

import SwiftUI

struct GuestFormSheet: View {
    /// Crédits encore disponibles, panier en cours déduit.
    let creditsRemaining: Int
    let onAdd: (_ prenom: String, _ nom: String, _ payer: GuestPayer) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var prenom = ""
    @State private var nom = ""
    @State private var payer: GuestPayer = .supplement
    @State private var hasSubmitted = false

    private var hasCredit: Bool { creditsRemaining > 0 }

    private var trimmedPrenom: String { prenom.trimmingCharacters(in: .whitespaces) }
    private var trimmedNom: String { nom.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityFields
                    payerPicker

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

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassFieldGroup {
                AuthField(kind: .firstName, systemImage: "person", placeholder: "Prénom", text: $prenom)
                FieldDivider()
                AuthField(kind: .lastName, systemImage: "textformat", placeholder: "Nom", text: $nom)
            }

            if hasSubmitted, let message = validationMessage {
                InlineMessage(kind: .error, message: message)
            }
        }
    }

    private var validationMessage: String? {
        if trimmedPrenom.isEmpty, trimmedNom.isEmpty { return "Renseigne le prénom et le nom de l'invité." }
        if trimmedPrenom.isEmpty { return "Le prénom de l'invité est obligatoire." }
        if trimmedNom.isEmpty { return "Le nom de l'invité est obligatoire." }
        return nil
    }

    // MARK: - Qui paie

    private var payerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Qui paie l'invité ?")
                .metaLabelStyle()

            VStack(spacing: 8) {
                payerOption(
                    .credit,
                    title: "Crédit invité",
                    detail: hasCredit
                        ? "Gratuit · \(creditsRemaining) restant\(creditsRemaining > 1 ? "s" : "")"
                        : "Crédit invité épuisé",
                    systemImage: "ticket",
                    isEnabled: hasCredit
                )

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
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isEnabled ? Brand.textSecondary : Brand.warning)
                }

                Spacer(minLength: 0)

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
