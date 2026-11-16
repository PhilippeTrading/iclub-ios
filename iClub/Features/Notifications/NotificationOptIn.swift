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
//  Place dans l'application
//    Le modificateur `offersNotificationOptIn` est posé sur l'écran de
//    réservation confirmée, l'écran de partie ouverte créée, la liste des
//    parties (après en avoir rejoint une), la conversation (après un premier
//    message envoyé) et l'espace entraîneur, chacun avec son message.
//
//  Règles (portées par `PushService`)
//    L'écran ne s'affiche que tant qu'iOS n'a jamais posé la question, et pas
//    dans les 7 jours qui suivent un « Pas maintenant ». « Activer » présente
//    la demande système, puis enregistre l'appareil pour les notifications
//    push.
//
//  Effets de bord
//    Date du refus gardée sur l'appareil (`UserDefaults`), demande
//    d'autorisation système, enregistrement APNs. Rien en base ici.
//

import SwiftUI

/// Raccourci d'écriture pour proposer les notifications depuis n'importe quel
/// écran.
extension View {
    /// Propose l'activation des notifications quand `condition` devient vraie,
    /// si iOS n'a encore jamais posé la question et que le membre n'a pas
    /// décliné notre écran récemment.
    ///
    /// - Parameters:
    ///   - condition: moment favorable (par exemple une partie qui vient
    ///     d'être rejointe) ; `true` pour proposer dès l'affichage.
    ///   - message: explication propre au contexte, parmi les messages de
    ///     `NotificationOptInSheet` (parties par défaut).
    /// - Returns: la vue munie de la proposition.
    func offersNotificationOptIn(
        when condition: Bool,
        message: String = NotificationOptInSheet.gamesMessage
    ) -> some View {
        modifier(NotificationOptInModifier(condition: condition, message: message))
    }
}

/// Modificateur qui attend le bon moment puis présente l'écran d'explication.
private struct NotificationOptInModifier: ViewModifier {
    /// Moment favorable atteint.
    let condition: Bool
    /// Explication affichée.
    let message: String

    /// Vrai pendant que l'écran d'explication est présenté.
    @State private var isPresented = false

    /// Ajoute l'attente du bon moment et la feuille d'explication.
    ///
    /// - Parameter content: écran qui propose les notifications.
    /// - Returns: l'écran muni de la proposition.
    func body(content: Content) -> some View {
        content
            // Relancé à chaque changement de `condition`.
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
                    // « Activer » : demande système, et enregistrement APNs si
                    // le membre accepte. « Pas maintenant » : la date est
                    // retenue, l'écran se tait sept jours.
                    if accepted {
                        Task { await PushService.requestSystemAuthorization() }
                    } else {
                        PushService.declineOptIn()
                    }
                }
                // Le geste de glisser pour fermer est désactivé : le membre
                // choisit entre « Activer » et « Pas maintenant ».
                .interactiveDismissDisabled()
            }
    }
}

/// Écran d'explication en demi-feuille : pictogramme, titre et message
/// adaptés au contexte, bouton « Activer les notifications » et lien « Pas
/// maintenant ».
struct NotificationOptInSheet: View {
    /// Message par défaut : parties ouvertes sur les créneaux habituels.
    static let gamesMessage = "Soyez prévenu quand une partie cherche un joueur sur vos créneaux habituels."
    /// Message de la messagerie.
    static let messagesMessage = "Soyez prévenu quand on vous répond, même quand l'app est fermée."
    /// Message de l'espace entraîneur (rappel d'appel).
    static let attendanceMessage = "Recevez un rappel au début de chacun de vos cours, pour faire l'appel en un geste."

    /// Explication affichée ; choisit aussi le titre.
    var message: String = gamesMessage
    /// Appelé avec `true` pour « Activer », `false` pour « Pas maintenant ».
    let onChoice: (Bool) -> Void

    /// Titre déduit du message (comparaison avec les messages connus).
    private var title: String {
        switch message {
        case Self.messagesMessage: "Ne manquez aucune réponse"
        case Self.attendanceMessage: "N'oubliez plus l'appel"
        default: "Ne manquez plus une partie"
        }
    }

    /// Pictogramme, titre, message, puis les deux choix, en demi-feuille.
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

            // Les deux choix.
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

/// Aperçu Xcode de l'écran, avec le message par défaut.
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        NotificationOptInSheet { _ in }
    }
}
