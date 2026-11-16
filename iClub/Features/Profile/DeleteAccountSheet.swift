//
//  DeleteAccountSheet.swift
//  iClub
//
//  Rôle
//    Confirmation de suppression du compte, en deux étapes.
//
//    1. Cette feuille dit clairement ce qui est supprimé **et ce que le club
//       conserve**. Cacher la seconde partie serait une erreur : un membre qui
//       découvre après coup que le club a gardé des traces se sent trompé,
//       alors que l'expliquer avant est parfaitement accepté.
//    2. Une alerte à rôle destructif, avec un libellé explicite. Un seul geste
//       ne suffit donc jamais à supprimer un compte.
//
//  Place dans l'application
//    Présentée par ProfileView (bouton « Supprimer mon compte »). Elle
//    n'écrit rien elle-même : la confirmation finale appelle `onConfirm`, et
//    c'est ProfileView qui lance la suppression (AuthService.deleteMyAccount,
//    fonction SQL `delete_my_account`, migration 20261017100000).
//
//  Ce que fait réellement la suppression
//    Le profil est anonymisé (nom « Adhérent », prénom « supprimé », adresse
//    remplacée par une adresse non routable, téléphone, date de naissance,
//    sexe et photo effacés ; « Adhérent supprimé » dans les participants des
//    réservations passées), l'utilisateur
//    d'authentification est supprimé, les réservations à venir créées par le
//    membre sont annulées et il est retiré de celles où il n'est que
//    participant ; l'historique (réservations passées, adhésions,
//    comptabilité) reste, sans son nom.
//
//  Points d'attention
//    Limite connue : la fonction SQL ne touche ni aux inscriptions aux cours
//    et événements, ni aux pièces justificatives déposées (lignes et fichiers
//    du compartiment `documents-adherents`), ni aux messages envoyés, ni aux
//    liens de famille. La feuille n'en parle pas.
//

import SwiftUI

/// Feuille d'explication avant la suppression du compte.
struct DeleteAccountSheet: View {
    /// Suppression en cours (fournie par ProfileView) : boutons désactivés et
    /// fermeture par glissement bloquée.
    let isDeleting: Bool
    /// Appelée après la confirmation finale.
    let onConfirm: () -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Alerte de confirmation finale ouverte.
    @State private var showFinalConfirmation = false

    /// En-tête, ce qui est supprimé, ce que le club conserve, l'effet sur les
    /// réservations à venir, et le bouton « Continuer la suppression » en bas.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    // Ce qui disparaît.
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

                    // Ce qui reste, anonymisé.
                    section(
                        title: "Ce que le club conserve",
                        symbol: "archivebox",
                        tint: Brand.navy700,
                        items: [
                            "Vos réservations passées et vos adhésions, sans votre nom",
                            "Elles servent à la comptabilité du club et à son historique de fréquentation",
                        ]
                    )

                    // Effet sur l'avenir : places rendues.
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
            // Seconde étape : alerte destructive explicite.
            .alert("Supprimer définitivement ?", isPresented: $showFinalConfirmation) {
                Button("Supprimer mon compte", role: .destructive) { onConfirm() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Cette action est irréversible. Vous ne pourrez plus vous connecter avec ce compte.")
            }
            // Pendant la suppression, la feuille ne se ferme pas d'un geste.
            .interactiveDismissDisabled(isDeleting)
        }
        // Pleine hauteur : à mi-hauteur, le bouton d'action en bas de la
        // feuille sortait de l'écran.
        .presentationDetents([.large])
    }

    // MARK: - Contenu

    /// Icône, titre « Avant de continuer » et phrase d'introduction.
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

    /// Carte titrée avec une liste à puces.
    /// - Parameters:
    ///   - title: intitulé de la carte.
    ///   - symbol: symbole SF Symbols devant l'intitulé.
    ///   - tint: couleur de l'icône et des puces.
    ///   - items: lignes de la liste.
    /// - Returns: la carte.
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
                        // Puce ronde de 5 points, calée sur la ligne de base du
                        // texte.
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

    /// Barre du bas : « Continuer la suppression », en rouge, qui ouvre
    /// l'alerte finale ; indicateur d'activité pendant la suppression.
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

/// Aperçu Xcode de la feuille, ouverte sur un fond vide.
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        DeleteAccountSheet(isDeleting: false, onConfirm: {})
    }
}
