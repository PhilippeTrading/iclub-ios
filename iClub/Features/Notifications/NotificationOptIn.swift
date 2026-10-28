//
//  NotificationOptIn.swift
//  iClub
//
//  Notre écran d'explication, présenté avant la demande système.
//
//  iOS n'offre qu'une seule chance de poser la question : un refus ne se
//  rattrape ensuite que par les Réglages. On ne la pose donc qu'après un « oui »
//  du membre ici, et seulement après une première réservation ou une première
//  partie rejointe, quand il vient de voir à quoi sert l'app.
//

import SwiftUI

extension View {
    /// Propose l'activation des notifications quand `condition` devient vraie,
    /// si iOS n'a encore jamais posé la question et que le membre n'a pas
    /// décliné notre écran récemment.
    func offersNotificationOptIn(
        when condition: Bool,
        message: String = NotificationOptInSheet.gamesMessage
    ) -> some View {
        modifier(NotificationOptInModifier(condition: condition, message: message))
    }
}

private struct NotificationOptInModifier: ViewModifier {
    let condition: Bool
    let message: String

    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .task(id: condition) {
                guard condition else { return }
                // Laisse d'abord le membre voir sa confirmation.
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                if await PushService.shouldOfferOptIn() { isPresented = true }
            }
            .sheet(isPresented: $isPresented) {
                NotificationOptInSheet(message: message) { accepted in
                    isPresented = false
                    if accepted {
                        Task { await PushService.requestSystemAuthorization() }
                    } else {
                        PushService.declineOptIn()
                    }
                }
                // Glisser pour fermer vaut « Pas maintenant ».
                .interactiveDismissDisabled()
            }
    }
}

struct NotificationOptInSheet: View {
    static let gamesMessage = "Soyez prévenu quand une partie cherche un joueur sur vos créneaux habituels."
    static let messagesMessage = "Soyez prévenu quand on vous répond, même quand l'app est fermée."
    static let attendanceMessage = "Recevez un rappel au début de chacun de vos cours, pour faire l'appel en un geste."

    var message: String = gamesMessage
    let onChoice: (Bool) -> Void

    private var title: String {
        switch message {
        case Self.messagesMessage: "Ne manquez aucune réponse"
        case Self.attendanceMessage: "N'oubliez plus l'appel"
        default: "Ne manquez plus une partie"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Brand.navy700)
                .padding(.top, 28)

            Text(title)
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            PrimaryActionButton(title: "Activer les notifications", systemImage: "bell") {
                onChoice(true)
            }

            Button("Pas maintenant") { onChoice(false) }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
        .presentationBackground(Brand.background)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        NotificationOptInSheet { _ in }
    }
}
