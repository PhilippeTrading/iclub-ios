//
//  MessagesSheet.swift
//  iClub
//
//  Rôle
//    La feuille ouverte par la bulle : liste des conversations, puis une
//    conversation, ou la recherche d'un membre pour un nouveau message.
//
//  Place dans l'application
//    Présentée par MainTabView quand `MessagingCenter.isSheetPresented` passe à
//    vrai : tap sur la bulle (liste), bouton « Écrire » d'un écran ou tap sur
//    une notification (directement sur la conversation, par
//    `MessagingCenter.open`). Sa pile de navigation est `MessagingCenter.path`.
//
//  Données
//    MessagingCenter (liste issue de la fonction SQL `mes_conversations` :
//    titre ou autre personne, dernier message, non-lus, sourdine).
//
//  États de la liste
//    Messagerie non déployée (« Messagerie bientôt disponible »), premier
//    chargement (indicateur d'activité), aucune conversation, ou la liste.
//
//  Actions
//    Ouvrir une conversation ; écrire à un nouveau membre (crayon) ; glisser
//    une ligne vers la gauche pour couper ou rétablir ses notifications, et,
//    pour l'entraîneur du cours, supprimer le groupe (après confirmation).
//

import SwiftUI

/// Feuille de messagerie : sa propre pile de navigation, liste à la racine.
struct MessagesSheet: View {
    /// État partagé de la messagerie (pile, liste).
    @Environment(MessagingCenter.self) private var messaging
    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// La pile liée à `MessagingCenter.path`, avec ses deux destinations et le
    /// bouton « Fermer ».
    var body: some View {
        @Bindable var messaging = messaging

        NavigationStack(path: $messaging.path) {
            ConversationListView()
                .navigationDestination(for: ConversationRoute.self) { route in
                    ConversationView(conversationId: route.conversationId)
                }
                .navigationDestination(for: NewMessageRoute.self) { _ in
                    NewMessageView()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fermer", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        // La pile est remise à zéro en fermant : la bulle rouvre la liste.
        .onDisappear {
            messaging.path = NavigationPath()
            messaging.visibleConversationId = nil
        }
    }
}

// MARK: - Liste

/// Liste des conversations de l'utilisateur.
struct ConversationListView: View {
    /// État partagé de la messagerie.
    @Environment(MessagingCenter.self) private var messaging
    /// Session : profil de l'utilisateur pour la sourdine.
    @Environment(AuthController.self) private var auth

    /// Groupe dont la suppression attend confirmation.
    @State private var groupToDelete: ConversationSummary?

    /// L'état de la messagerie, puis la liste ; crayon « Nouveau message »
    /// quand la messagerie est disponible.
    var body: some View {
        Group {
            switch messaging.availability {
            // Fonction `mes_conversations` absente : migration non appliquée.
            case .unavailable:
                PhasePlaceholder(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "Messagerie bientôt disponible",
                    message: "Votre club n'a pas encore activé la messagerie."
                )
            // Aucune réponse encore : indicateur d'activité.
            case .unknown where !messaging.isLoaded:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                // Chargée : état vide, ou la liste.
                if messaging.conversations.isEmpty {
                    PhasePlaceholder(
                        systemImage: "bubble.left.and.bubble.right",
                        title: "Aucune conversation",
                        message: "Écrivez à un membre du club, ou à l'entraîneur d'un cours depuis sa fiche."
                    )
                } else {
                    list
                }
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Nouveau message : seulement si la messagerie répond.
            if messaging.availability == .available {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: NewMessageRoute()) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Nouveau message")
                }
            }
        }
        .refreshable { await messaging.reload() }
        // Relecture à chaque affichage de la liste.
        .task { await messaging.reload() }
    }

    /// La liste, ses actions de balayage et la confirmation de suppression.
    private var list: some View {
        List(messaging.conversations) { conversation in
            NavigationLink(value: ConversationRoute(conversationId: conversation.id)) {
                ConversationRow(conversation: conversation)
            }
            .listRowBackground(Brand.surface)
            // Glisser vers la gauche : sourdine pour soi, et suppression du
            // groupe pour l'entraîneur du cours.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if messaging.canDelete(conversation) {
                    Button {
                        groupToDelete = conversation
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                    .tint(Brand.error)
                }

                // « Activer » si la conversation est en sourdine, « Couper »
                // sinon.
                Button {
                    toggleMute(conversation)
                } label: {
                    if conversation.silencieux {
                        Label("Activer", systemImage: "bell")
                    } else {
                        Label("Couper", systemImage: "bell.slash")
                    }
                }
                .tint(conversation.silencieux ? Brand.success : Brand.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Confirmation : la suppression vaut pour tous les membres du groupe.
        .confirmationDialog(
            "Supprimer ce groupe ?",
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            titleVisibility: .visible,
            presenting: groupToDelete
        ) { conversation in
            Button("Supprimer pour tous", role: .destructive) {
                Task { await messaging.deleteGroup(conversation) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { conversation in
            Text("« \(conversation.displayTitle) » et tous ses messages disparaîtront pour l'ensemble des membres.")
        }
    }

    /// Ne touche que ses propres notifications : l'entraîneur et les autres
    /// membres continuent d'être prévenus.
    /// - Parameter conversation: la conversation à basculer.
    private func toggleMute(_ conversation: ConversationSummary) {
        guard let profileId = auth.sessionProfile?.id else { return }
        Haptics.selection()
        Task { await messaging.setMuted(!conversation.silencieux, conversation: conversation, profileId: profileId) }
    }
}

/// Ligne d'une conversation : pastille de groupe ou photo, titre, heure du
/// dernier message, aperçu, sourdine et nombre de non-lus.
private struct ConversationRow: View {
    /// La conversation résumée.
    let conversation: ConversationSummary

    /// Avatar à gauche ; titre et heure, puis aperçu et indicateurs.
    var body: some View {
        HStack(spacing: 12) {
            // Groupe : icône de groupe ; à deux : photo de l'autre personne.
            if conversation.isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.navy700)
                    .frame(width: 44, height: 44)
                    .background(Brand.navy700.opacity(0.12), in: .circle)
            } else {
                MemberAvatar(url: conversation.autreAvatarUrl, initials: conversation.initials, size: 44)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Titre en gras s'il reste des non-lus ; heure du dernier
                // message à droite.
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.displayTitle)
                        .font(.system(.subheadline, design: .rounded, weight: conversation.nonLus > 0 ? .bold : .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = conversation.dernierMessageLe {
                        Text(date.conversationTimestamp)
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }

                // Aperçu du dernier message (sur deux lignes), icône de
                // sourdine et pastille du nombre de non-lus.
                HStack(alignment: .top) {
                    Text(conversation.dernierMessage ?? "Aucun message pour l'instant")
                        .font(.footnote)
                        .foregroundStyle(conversation.nonLus > 0 ? Brand.textPrimary : Brand.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if conversation.silencieux {
                        MutedBubbleIcon()
                    }
                    if conversation.nonLus > 0 {
                        Text("\(conversation.nonLus)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Brand.navy700, in: .capsule)
                            .accessibilityLabel("\(conversation.nonLus) non lus")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Horodatage compact de la liste des conversations.
extension Date {
    /// « 14 h 05 » aujourd'hui, « hier », « lun. », puis « 12 oct. ».
    ///
    /// Le jour abrégé vaut pour les messages de moins de sept jours ; au-delà,
    /// la date abrégée (`shortFrenchDate`). Le tout en français, dans le fuseau
    /// de l'appareil.
    var conversationTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocale.french))
        }
        if calendar.isDateInYesterday(self) { return "hier" }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return frenchWeekdayAbbreviation
        }
        return shortFrenchDate
    }
}

/// Une bulle barrée : les notifications de cette conversation sont coupées,
/// pour ce membre seulement.
struct MutedBubbleIcon: View {
    /// Bulle et trait diagonal superposés, lus « Notifications coupées » par
    /// VoiceOver.
    var body: some View {
        ZStack {
            Image(systemName: "bubble.left")
            Image(systemName: "line.diagonal")
                .font(.system(size: 15, weight: .bold))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Brand.textSecondary)
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel("Notifications coupées")
    }
}
