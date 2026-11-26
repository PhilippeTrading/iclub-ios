//
//  MessagesSheet.swift
//  iClub
//
//  La feuille ouverte par la bulle : liste des conversations, puis une
//  conversation, ou la recherche d'un membre pour un nouveau message.
//

import SwiftUI

struct MessagesSheet: View {
    @Environment(MessagingCenter.self) private var messaging
    @Environment(\.dismiss) private var dismiss

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

struct ConversationListView: View {
    @Environment(MessagingCenter.self) private var messaging
    @Environment(AuthController.self) private var auth

    @State private var groupToDelete: ConversationSummary?

    var body: some View {
        Group {
            switch messaging.availability {
            case .unavailable:
                PhasePlaceholder(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "Messagerie bientôt disponible",
                    message: "Votre club n'a pas encore activé la messagerie."
                )
            case .unknown where !messaging.isLoaded:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
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
        .task { await messaging.reload() }
    }

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
    private func toggleMute(_ conversation: ConversationSummary) {
        guard let profileId = auth.sessionProfile?.id else { return }
        Haptics.selection()
        Task { await messaging.setMuted(!conversation.silencieux, conversation: conversation, profileId: profileId) }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
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
                            // Sur l'aplat bleu marine, très clair en mode
                            // sombre : `textOnInverse` (voir BrandPalette).
                            .foregroundStyle(Brand.textOnInverse)
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

extension Date {
    /// « 14 h 05 » aujourd'hui, « hier », « lun. », puis « 12 oct. ».
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
