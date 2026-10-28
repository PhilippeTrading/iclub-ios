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
    @FocusState private var isComposerFocused: Bool

    private var myId: UUID? { auth.sessionProfile?.id }

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
                            showsAuthor: showsAuthor(at: index)
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: muteBinding) {
                        Label("Sourdine", systemImage: "bell.slash")
                    }
                } label: {
                    Image(systemName: isMuted ? "bell.slash.fill" : "ellipsis.circle")
                }
                .accessibilityLabel("Options de la conversation")
            }
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
                    .foregroundStyle(.white)
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

    /// Le nom de l'auteur n'est rappelé qu'en groupe, et seulement quand il
    /// change d'un message à l'autre.
    private func showsAuthor(at index: Int) -> Bool {
        guard summary?.isGroup == true else { return false }
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 48) }

            if !isMine && showsAuthor {
                MemberAvatar(url: author?.avatarUrl, initials: author?.initials ?? "?", size: 28)
            } else if !isMine {
                Color.clear.frame(width: 0, height: 0)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if showsAuthor, let author {
                    Text(author.firstName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }

                Text(message.corps)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? Color.white : Brand.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isMine ? Brand.navy700 : Brand.surface,
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
        .accessibilityElement(children: .combine)
    }
}
