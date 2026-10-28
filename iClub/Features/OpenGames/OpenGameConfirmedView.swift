//
//  OpenGameConfirmedView.swift
//  iClub
//
//  Écran de succès après l'ouverture d'une partie.
//
//  La route porte toutes ses données : elle reste affichable même si le
//  magasin se recharge derrière elle.
//

import SwiftUI

struct OpenGameConfirmation: Hashable {
    let gameId: UUID
    let courtName: String
    let sport: Sport
    let date: Date
    let slot: TimeSlot
    let format: GameFormat
    let levelLabel: String
}

struct OpenGameConfirmedView: View {
    let confirmation: OpenGameConfirmation

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                successMark
                recapCard
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("")
        // Le tunnel est déjà refermé : le geste arrière ne doit pas ramener sur
        // un formulaire dont la partie est déjà créée.
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) { listBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Le membre vient de voir la valeur de l'app : c'est le moment de
        // proposer les notifications de parties.
        .offersNotificationOptIn(when: true)
    }

    private var successMark: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(Brand.success)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text("Votre partie est ouverte")
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)

            Text("\(confirmation.format.capacity) joueurs attendus — les autres membres peuvent maintenant vous rejoindre.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var recapCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(confirmation.date.longFrenchDate)
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    BrandChip(
                        title: confirmation.format.displayName,
                        tint: confirmation.sport.accent
                    )
                }

                Text(confirmation.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                Divider().opacity(0.4)

                row(systemImage: confirmation.sport.symbolName, text: confirmation.courtName)
                row(systemImage: "chart.bar", text: confirmation.levelLabel)
                row(
                    systemImage: "person.2",
                    text: "\(confirmation.format.capacity) joueurs · vous êtes inscrit"
                )
            }
        }
    }

    private func row(systemImage: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.textPrimary)

            Spacer(minLength: 0)
        }
    }

    private var listBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(title: "Voir les parties ouvertes", systemImage: "list.bullet") {
                router.openGamesPath = NavigationPath()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
