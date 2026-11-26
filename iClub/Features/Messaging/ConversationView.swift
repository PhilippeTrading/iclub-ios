//
//  ConversationView.swift
//  iClub
//
//  Une conversation : messages par ordre chronologique, pagination par 50 en
//  remontant, envoi optimiste, temps réel, sourdine.
//
//  Pas d'édition, pas de suppression, pas de pièce jointe, pas d'accusé de
//  lecture affiché à l'autre : c'est voulu pour cette version.
//

import Supabase
import SwiftUI

struct ConversationView: View {
    let conversationId: UUID

    @Environment(AuthController.self) private var auth
    @Environment(MessagingCenter.self) private var messaging

    @State private var messages: [ChatMessage] = []
    @State private var participants: [UUID: ConversationParticipant] = [:]
    @State private var hasOlder = false
    @State private var isLoadingOlder = false
    @State private var isLoaded = false
    @State private var draft = ""
    @State private var sendError: String?
    @State private var isMuted = false
    @State private var didSend = false
    /// Membre dont la fiche est ouverte depuis sa photo ou son nom.
    @State private var selectedAuthor: ConversationParticipant?
    @State private var showsMembers = false
    @FocusState private var isComposerFocused: Bool

    private var myId: UUID? { auth.sessionProfile?.id }

    /// L'autre personne d'une conversation à deux.
    private var otherParticipant: ConversationParticipant? {
        if let id = summary?.autreProfileId, let person = participants[id] { return person }
        return participants.values.first { $0.profileId != myId }
    }

    /// Moi d'abord, puis les autres par ordre alphabétique.
    private var sortedParticipants: [ConversationParticipant] {
        participants.values.sorted { a, b in
            if a.profileId == myId { return true }
            if b.profileId == myId { return false }
            return a.nomAffiche.localizedCompare(b.nomAffiche) == .orderedAscending
        }
    }

    private var summary: ConversationSummary? {
        messaging.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if hasOlder {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            if isLoadingOlder {
                                ProgressView()
                            } else {
                                Text("Messages précédents")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.vertical, 8)
                    }

                    if isLoaded && messages.isEmpty {
                        Text("Aucun message. Écrivez le premier.")
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 40)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubbleRow(
                            message: message,
                            isMine: message.auteurProfileId == myId,
                            author: participants[message.auteurProfileId],
                            showsAuthor: showsAuthor(at: index),
                            onSelectAuthor: { selectedAuthor = participants[message.auteurProfileId] }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(summary?.displayTitle ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // En groupe : la liste des membres. À deux : la fiche de l'autre.
            ToolbarItem(placement: .topBarTrailing) {
                if summary?.isGroup == true {
                    Button {
                        showsMembers = true
                    } label: {
                        Image(systemName: "person.2.circle")
                    }
                    .accessibilityLabel("Membres du groupe")
                } else if let other = otherParticipant {
                    Button {
                        selectedAuthor = other
                    } label: {
                        MemberAvatar(url: other.avatarUrl, initials: other.initials, size: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profil de \(other.nomAffiche)")
                }
            }
        }
        .sheet(isPresented: $showsMembers) {
            GroupMembersSheet(
                title: summary?.displayTitle ?? "Groupe",
                members: sortedParticipants,
                myId: myId,
                isMuted: muteBinding
            )
        }
        .sheet(item: $selectedAuthor) { author in
            MemberCardSheet(
                profileId: author.profileId,
                fallbackName: author.nomAffiche,
                fallbackAvatar: author.avatarUrl,
                // Écrire en privé n'a de sens que depuis un groupe, ou vers
                // quelqu'un d'autre que la personne déjà en face.
                canWritePrivately: summary?.isGroup == true || summary?.autreProfileId != author.profileId
            )
        }
        .alert("Message non envoyé", isPresented: sendErrorBinding) {
            Button("OK") { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
        // Premier message envoyé : c'est le moment de proposer d'être prévenu
        // des réponses.
        .offersNotificationOptIn(when: didSend, message: NotificationOptInSheet.messagesMessage)
        .onAppear { messaging.visibleConversationId = conversationId }
        .onDisappear {
            if messaging.visibleConversationId == conversationId { messaging.visibleConversationId = nil }
        }
        .task(id: conversationId) {
            isMuted = summary?.silencieux ?? false
            await loadInitial()
            await observe()
        }
    }

    // MARK: - Saisie

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Brand.surface, in: .rect(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Brand.hairline, lineWidth: 0.5)
                }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    // Envoi possible : aplat bleu marine, très clair en mode
                    // sombre, d'où `textOnInverse` (voir BrandPalette). Bouton
                    // inactif : flèche blanche sur le gris, comme avant.
                    .foregroundStyle(canSend ? Brand.textOnInverse : Color.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Brand.navy700 : Brand.textSecondary.opacity(0.4), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Envoyer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && trimmedDraft.count <= MessagingService.maxLength
    }

    // MARK: - Chargement

    private func loadInitial() async {
        async let people = try? MessagingService.participants(of: conversationId)
        async let page = try? MessagingService.messages(in: conversationId)
        let (loadedPeople, loadedPage) = await (people, page)

        participants = Dictionary((loadedPeople ?? []).map { ($0.profileId, $0) }, uniquingKeysWith: { a, _ in a })
        messages = loadedPage ?? []
        hasOlder = (loadedPage?.count ?? 0) >= MessagingService.pageSize
        isLoaded = true

        await MessagingService.markRead(conversationId)
        await messaging.reload()
    }

    private func loadOlder() async {
        guard let oldest = messages.first?.createdAt, !isLoadingOlder else { return }
        isLoadingOlder = true
        if let page = try? await MessagingService.messages(in: conversationId, before: oldest) {
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: page.filter { !known.contains($0.id) }, at: 0)
            hasOlder = page.count >= MessagingService.pageSize
        }
        isLoadingOlder = false
    }

    /// Nouveaux messages de cette conversation, tant qu'elle est ouverte.
    private func observe() async {
        let channel = Supa.client.channel("conversation-\(conversationId.uuidString)")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: .eq("conversation_id", value: conversationId.uuidString)
        )

        try? await channel.subscribeWithError()
        defer { Task { await Supa.client.removeChannel(channel) } }

        for await action in inserts {
            guard let message = try? action.decodeRecord(as: ChatMessage.self, decoder: JSONDecoder()) else { continue }
            receive(message)
            if message.auteurProfileId != myId {
                await MessagingService.markRead(conversationId)
                await messaging.reload()
                // Un nouvel auteur dans un groupe (inscrit arrivé depuis).
                if participants[message.auteurProfileId] == nil,
                   let people = try? await MessagingService.participants(of: conversationId) {
                    participants = Dictionary(people.map { ($0.profileId, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
        }
    }

    /// Ajoute un message, sans doublon : le temps réel renvoie aussi les
    /// messages qu'on vient d'envoyer.
    private func receive(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    // MARK: - Envoi

    private func send() {
        let body = trimmedDraft
        guard canSend, let myId else { return }
        draft = ""
        Haptics.tap()

        // Affiché tout de suite, remplacé par la ligne de la base à l'arrivée.
        let temporaryId = UUID()
        messages.append(ChatMessage(
            id: temporaryId, conversationId: conversationId, auteurProfileId: myId,
            corps: body, createdAt: .now, isPending: true
        ))

        Task {
            do {
                let realId = try await MessagingService.send(body, to: conversationId)
                if let index = messages.firstIndex(where: { $0.id == temporaryId }) {
                    if messages.contains(where: { $0.id == realId }) {
                        // Le temps réel est passé avant la réponse.
                        messages.remove(at: index)
                    } else {
                        let pending = messages[index]
                        messages[index] = ChatMessage(
                            id: realId, conversationId: pending.conversationId, auteurProfileId: pending.auteurProfileId,
                            corps: pending.corps, createdAt: pending.createdAt, isPending: false
                        )
                    }
                }
                didSend = true
                await messaging.reload()
            } catch {
                messages.removeAll { $0.id == temporaryId }
                draft = body
                sendError = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    // MARK: - Sourdine

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { isMuted },
            set: { newValue in
                guard let myId else { return }
                let previous = isMuted
                isMuted = newValue
                Task {
                    do {
                        try await MessagingService.setMuted(newValue, conversationId: conversationId, profileId: myId)
                        Haptics.selection()
                        await messaging.reload()
                    } catch {
                        isMuted = previous
                        sendError = "La sourdine n'a pas pu être modifiée."
                    }
                }
            }
        )
    }

    // MARK: - Outils

    /// Photo, prénom et nom de l'auteur au début de chaque suite de messages
    /// qu'il envoie, en groupe comme à deux.
    private func showsAuthor(at index: Int) -> Bool {
        let message = messages[index]
        guard message.auteurProfileId != myId else { return false }
        return index == 0 || messages[index - 1].auteurProfileId != message.auteurProfileId
    }

    private var sendErrorBinding: Binding<Bool> {
        Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })
    }
}

// MARK: - Bulle de message

private struct MessageBubbleRow: View {
    let message: ChatMessage
    let isMine: Bool
    let author: ConversationParticipant?
    let showsAuthor: Bool
    let onSelectAuthor: () -> Void

    /// Largeur réservée à la photo, pour que les bulles d'une même personne
    /// restent alignées sous la première.
    private let avatarColumn: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 48) }

            if !isMine {
                if showsAuthor {
                    Button(action: onSelectAuthor) {
                        MemberAvatar(url: author?.avatarUrl, initials: author?.initials ?? "?", size: avatarColumn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voir le profil de \(author?.nomAffiche ?? "ce membre")")
                } else {
                    Color.clear.frame(width: avatarColumn, height: 1)
                }
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if showsAuthor, !isMine {
                    Button(action: onSelectAuthor) {
                        Text(author?.nomAffiche ?? "Membre")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.navy700)
                    }
                    .buttonStyle(.plain)
                }

                Text(message.corps)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? Color.white : Brand.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Les bulles reçues sont teintées : sur un fond blanc, une
                    // bulle blanche ne se verrait pas.
                    .background(
                        isMine ? Brand.navy700 : Brand.navy700.opacity(0.08),
                        in: .rect(cornerRadius: 18, style: .continuous)
                    )
                    .opacity(message.isPending ? 0.6 : 1)
                    .textSelection(.enabled)

                Text(message.createdAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocale.french)))
                    .font(.caption2)
                    .foregroundStyle(Brand.textSecondary)
            }

            if !isMine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(.top, showsAuthor ? 6 : 0)
    }
}

// MARK: - Membres du groupe

/// Les membres d'un groupe ; un tap ouvre la fiche de l'un d'eux. La sourdine,
/// qui était dans le menu « … », est rangée ici.
private struct GroupMembersSheet: View {
    let title: String
    let members: [ConversationParticipant]
    let myId: UUID?
    @Binding var isMuted: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(MessagingCenter.self) private var messaging
    @State private var selected: ConversationParticipant?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $isMuted) {
                        Label("Couper les notifications", systemImage: "bell.slash")
                    }
                    .tint(Brand.navy700)
                } footer: {
                    Text("Pour vous seulement : les autres membres continuent d'être prévenus.")
                }

                Section("\(members.count) membre\(members.count > 1 ? "s" : "")") {
                    ForEach(members) { member in
                        Button {
                            if member.profileId != myId { selected = member }
                        } label: {
                            HStack(spacing: 12) {
                                MemberAvatar(url: member.avatarUrl, initials: member.initials, size: 38)
                                Text(member.profileId == myId ? "\(member.nomAffiche) (vous)" : member.nomAffiche)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)
                                Spacer()
                                if member.profileId != myId {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Brand.textSecondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(item: $selected) { member in
                MemberCardSheet(profileId: member.profileId, fallbackName: member.nomAffiche, fallbackAvatar: member.avatarUrl)
            }
        }
        .presentationDetents([.medium, .large])
        // « Envoyer un message privé » depuis une fiche : la conversation change
        // derrière, la liste des membres n'a plus lieu d'être.
        .onChange(of: messaging.path) { _, _ in dismiss() }
    }
}
