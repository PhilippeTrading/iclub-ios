//
//  DeleteAccountSheet.swift
//  iClub
//
//  Confirmation de suppression du compte, en deux étapes.
//
//  1. Cette feuille dit clairement ce qui est supprimé **et ce que le club
//     conserve**. Cacher la seconde partie serait une erreur : un membre qui
//     découvre après coup que le club a gardé des traces se sent trompé,
//     alors que l'expliquer avant est parfaitement accepté.
//  2. Une alerte à rôle destructif, avec un libellé explicite. Un seul geste
//     ne suffit donc jamais à supprimer un compte.
//

import SwiftUI

struct DeleteAccountSheet: View {
    let isDeleting: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showFinalConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    section(
                        title: "Ce qui est supprimé",
                        symbol: "trash",
                        tint: Brand.error,
                        items: [
                            "Votre accès à l'application",
                            "Votre nom et votre prénom",
                            "Votre adresse e-mail et votre téléphone",
                            "Votre date de naissance et votre sexe",
                            "Votre photo de profil",
                        ]
                    )

                    section(
                        title: "Ce que le club conserve",
                        symbol: "archivebox",
                        tint: Brand.navy700,
                        items: [
                            "Vos réservations passées et vos adhésions, sans votre nom",
                            "Elles servent à la comptabilité du club et à son historique de fréquentation",
                        ]
                    )

                    InlineMessage(
                        kind: .info,
                        message: "Vos réservations et parties à venir seront annulées, et vos places rendues aux autres adhérents."
                    )

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Supprimer mon compte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .safeAreaInset(edge: .bottom) { continueBar }
            .alert("Supprimer définitivement ?", isPresented: $showFinalConfirmation) {
                Button("Supprimer mon compte", role: .destructive) { onConfirm() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Cette action est irréversible. Vous ne pourrez plus vous connecter avec ce compte.")
            }
            .interactiveDismissDisabled(isDeleting)
        }
        // Pleine hauteur : à mi-hauteur, le bouton d'action en bas de la
        // feuille sortait de l'écran.
        .presentationDetents([.large])
    }

    // MARK: - Contenu

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.error)

            Text("Avant de continuer")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)

            Text("La suppression efface vos données personnelles. Voici exactement ce qu'elle implique.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
        }
    }

    private func section(title: String, symbol: String, tint: Color, items: [String]) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .metaLabelStyle()
                }

                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(tint.opacity(0.6))
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(item)
                            .font(.footnote)
                            .foregroundStyle(Brand.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Action

    private var continueBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: "Continuer la suppression",
                systemImage: "trash",
                isLoading: isDeleting,
                tint: Brand.error
            ) {
                showFinalConfirmation = true
            }
            .disabled(isDeleting)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        DeleteAccountSheet(isDeleting: false, onConfirm: {})
    }
}
