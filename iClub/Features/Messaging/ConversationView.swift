//
//  ConversationView.swift
//  iClub
//
//  Rôle
//    Une conversation : messages par ordre chronologique, pagination par 50 en
//    remontant, envoi optimiste, temps réel, sourdine.
//
//    Pas d'édition, pas de suppression, pas de pièce jointe, pas d'accusé de
//    lecture affiché à l'autre : c'est voulu pour cette version.
//
//  Place dans l'application
//    Poussée dans la pile de la feuille de messagerie (route
//    `ConversationRoute`) : tap dans la liste, bouton « Écrire » d'un écran,
//    tap sur une notification. Mène à la fiche d'un membre (MemberCardSheet)
//    et, pour un groupe, à la liste de ses membres (GroupMembersSheet, plus
//    bas dans ce fichier).
//
//  Données (MessagingService, migration 20261023100000_messagerie)
//    - table `messages` : pages de 50, des plus récents aux plus anciens, lues
//      directement (la RLS « messages_lecture » réserve la lecture aux
//      participants) ;
//    - fonction `participants_conversation` : nom et photo des participants
//      (la fiche d'un membre n'est pas lisible autrement) ;
//    - fonction `envoyer_message` : insère le message (texte nettoyé de ses
//      blancs, 1 à 4 000 caractères), met à jour la date du dernier message
//      et marque la conversation lue pour l'auteur ;
//    - fonction `marquer_conversation_lue` : à l'ouverture et à chaque message
//      reçu pendant l'affichage ;
//    - sourdine : colonne `silencieux` de sa propre ligne de
//      `conversation_participants`.
//    Temps réel : abonnement Supabase aux insertions de `messages` filtrées sur
//    cette conversation, tant que l'écran est affiché.
//
//  Effets de bord
//    La notification push envoyée aux autres participants part du webhook de
//    la base (fonction Edge `push-message`), pas de l'app. Pendant que l'écran
//    est affiché, `MessagingCenter.visibleConversationId` empêche l'affichage
//    des notifications de cette conversation. Le premier envoi propose
//    d'activer les notifications.
//
//  Points d'attention
//    La pagination remonte avec « created_at strictement avant le plus ancien
//    message affiché » : deux messages de même horodatage, à la limite d'une
//    page, pourraient ne pas être tous chargés.
//

import Supabase
import SwiftUI

/// Écran d'une conversation, à deux ou de groupe.
struct ConversationView: View {
    /// Identifiant de la conversation (`conversations.id`).
    let conversationId: UUID

    /// Session : identifiant de l'utilisateur (« moi »).
    @Environment(AuthController.self) private var auth
    /// État partagé : résumé de la conversation, liste à rafraîchir.
    @Environment(MessagingCenter.self) private var messaging

    /// Messages affichés, du plus ancien au plus récent.
    @State private var messages: [ChatMessage] = []
    /// Participants, par profil : nom et photo des auteurs.
    @State private var participants: [UUID: ConversationParticipant] = [:]
    /// Une page pleine a été lue : il peut rester des messages plus anciens.
    @State private var hasOlder = false
    /// Lecture d'une page plus ancienne en cours.
    @State private var isLoadingOlder = false
    /// Premier chargement terminé.
    @State private var isLoaded = false
    /// Texte en cours de saisie.
    @State private var draft = ""
    /// Message de l'alerte « Message non envoyé » (ou échec de sourdine).
    @State private var sendError: String?
    /// Sourdine de l'utilisateur pour cette conversation.
    @State private var isMuted = false
    /// Un message a été envoyé depuis l'ouverture : déclenche la proposition
    /// d'activer les notifications.
    @State private var didSend = false
    /// Membre dont la fiche est ouverte depuis sa photo ou son nom.
    @State private var selectedAuthor: ConversationParticipant?
    /// Feuille des membres du groupe ouverte.
    @State private var showsMembers = false
    /// Focus clavier du champ de saisie.
    @FocusState private var isComposerFocused: Bool

    /// Identifiant de l'utilisateur connecté.
    private var myId: UUID? { auth.sessionProfile?.id }

    /// L'autre personne d'une conversation à deux.
    ///
    /// Celle que désigne le résumé (`autre_profile_id`), sinon le premier
    /// participant qui n'est pas l'utilisateur.
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

    /// Résumé de la conversation dans la liste de MessagingCenter (titre,
    /// groupe ou non, sourdine) ; `nil` tant que la liste ne la contient pas.
    private var summary: ConversationSummary? {
        messaging.conversations.first { $0.id == conversationId }
    }

    /// Fil des messages (calé en bas), zone de saisie, barre et feuilles.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // Bouton « Messages précédents » tant qu'une page pleine a
                    // été lue.
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

                    // Conversation vide, une fois chargée.
                    if isLoaded && messages.isEmpty {
                        Text("Aucun message. Écrivez le premier.")
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 40)
                    }

                    // Les bulles, avec l'auteur au début de chaque suite de
                    // messages d'une même personne.
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
            // Ouvre sur les derniers messages.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Nouveau dernier message (envoyé ou reçu) : on descend jusqu'à
            // lui. Charger une page plus ancienne ne change pas le dernier.
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .background(Brand.background.ignoresSafeArea())
        // Zone de saisie fixée en bas, au-dessus du clavier.
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
        // Membres du groupe, avec la sourdine.
        .sheet(isPresented: $showsMembers) {
            GroupMembersSheet(
                title: summary?.displayTitle ?? "Groupe",
                members: sortedParticipants,
                myId: myId,
                isMuted: muteBinding
            )
        }
        // Fiche d'un auteur (photo, nom, âge, classements).
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
        // Échec d'envoi (le texte est remis dans le champ) ou de sourdine.
        .alert("Message non envoyé", isPresented: sendErrorBinding) {
            Button("OK") { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
        // Premier message envoyé : c'est le moment de proposer d'être prévenu
        // des réponses.
        .offersNotificationOptIn(when: didSend, message: NotificationOptInSheet.messagesMessage)
        // Conversation à l'écran : ses notifications ne s'affichent pas.
        .onAppear { messaging.visibleConversationId = conversationId }
        // Ne remet à zéro que si une autre conversation n'a pas déjà pris la
        // place.
        .onDisappear {
            if messaging.visibleConversationId == conversationId { messaging.visibleConversationId = nil }
        }
        // Chargement, puis écoute du temps réel jusqu'à la sortie de l'écran
        // (la tâche est alors annulée).
        .task(id: conversationId) {
            isMuted = summary?.silencieux ?? false
            await loadInitial()
            await observe()
        }
    }

    // MARK: - Saisie

    /// Champ de saisie extensible (une à six lignes) et bouton d'envoi, bleu
    /// marine quand l'envoi est possible, grisé sinon.
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

    /// Texte saisi sans blancs ni retours à la ligne aux extrémités : c'est
    /// lui qui est envoyé.
    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Envoi possible : texte non vide d'au plus 4 000 caractères
    /// (`MessagingService.maxLength`, la même borne que la contrainte de la
    /// table `messages`).
    private var canSend: Bool {
        !trimmedDraft.isEmpty && trimmedDraft.count <= MessagingService.maxLength
    }

    // MARK: - Chargement

    /// Participants et dernière page de messages en parallèle, puis
    /// conversation marquée lue et liste rafraîchie (non-lus, bulle, pastille).
    /// Lectures tolérantes : un échec donne une liste vide.
    private func loadInitial() async {
        async let people = try? MessagingService.participants(of: conversationId)
        async let page = try? MessagingService.messages(in: conversationId)
        let (loadedPeople, loadedPage) = await (people, page)

        participants = Dictionary((loadedPeople ?? []).map { ($0.profileId, $0) }, uniquingKeysWith: { a, _ in a })
        messages = loadedPage ?? []
        // Page pleine : il peut en rester de plus anciens.
        hasOlder = (loadedPage?.count ?? 0) >= MessagingService.pageSize
        isLoaded = true

        await MessagingService.markRead(conversationId)
        await messaging.reload()
    }

    /// Page de messages plus anciens que le premier affiché, ajoutée en tête
    /// sans doublon. Un échec est ignoré (le bouton reste proposé).
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
    ///
    /// Canal Realtime propre à la conversation, filtré sur `conversation_id`.
    /// Un message reçu d'un autre est aussitôt marqué lu, la liste rafraîchie,
    /// et les participants relus si l'auteur est inconnu. Le canal est retiré
    /// à la fin de la boucle (sortie de l'écran).
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
            // Ligne illisible : ignorée.
            guard let message = try? action.decodeRecord(as: ChatMessage.self, decoder: JSONDecoder()) else { continue }
            receive(message)
            // Message d'un autre participant : lu, puisque la conversation est
            // à l'écran.
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
    ///
    /// Un message déjà présent (même identifiant) est remplacé, sinon ajouté à
    /// la fin.
    /// - Parameter message: le message reçu.
    private func receive(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    // MARK: - Envoi

    /// Envoi optimiste : la bulle s'affiche aussitôt, en semi-transparence,
    /// puis prend l'identifiant rendu par `envoyer_message`. En cas d'échec,
    /// la bulle disparaît, le texte revient dans le champ et une alerte
    /// s'affiche.
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
                // La bulle provisoire prend l'identifiant de la base, sauf si
                // la ligne réelle est déjà arrivée par le temps réel.
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
                // Liste rafraîchie : dernier message et ordre des conversations.
                await messaging.reload()
            } catch {
                // Refus (message vide, plus participant) ou réseau : retour
                // au brouillon.
                messages.removeAll { $0.id == temporaryId }
                draft = body
                sendError = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    // MARK: - Sourdine

    /// Interrupteur « Couper les notifications » de la liste des membres.
    ///
    /// Optimiste : l'interrupteur bascule tout de suite, la ligne de
    /// `conversation_participants` est écrite, et l'interrupteur revient en
    /// arrière avec un message si l'écriture échoue.
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
    ///
    /// Jamais pour ses propres messages.
    /// - Parameter index: position du message dans `messages`.
    /// - Returns: vrai pour le premier message d'une suite d'un autre auteur.
    private func showsAuthor(at index: Int) -> Bool {
        let message = messages[index]
        guard message.auteurProfileId != myId else { return false }
        return index == 0 || messages[index - 1].auteurProfileId != message.auteurProfileId
    }

    /// Ouvre l'alerte d'échec tant qu'un message est posé ; la fermer l'efface.
    private var sendErrorBinding: Binding<Bool> {
        Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })
    }
}

// MARK: - Bulle de message

/// Une bulle : à droite et pleine de bleu marine pour ses propres messages, à
/// gauche et teintée pour les autres, avec l'heure dessous.
private struct MessageBubbleRow: View {
    /// Le message.
    let message: ChatMessage
    /// Message de l'utilisateur.
    let isMine: Bool
    /// Auteur, s'il est connu (photo, nom).
    let author: ConversationParticipant?
    /// Afficher photo et nom (début d'une suite de messages d'un autre).
    let showsAuthor: Bool
    /// Ouvre la fiche de l'auteur.
    let onSelectAuthor: () -> Void

    /// Largeur réservée à la photo, pour que les bulles d'une même personne
    /// restent alignées sous la première.
    private let avatarColumn: CGFloat = 34

    /// Marge de 48 points du côté opposé, colonne de photo pour les messages
    /// reçus, puis nom, bulle et heure.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 48) }

            // Messages reçus : la photo (cliquable) au début d'une suite, une
            // colonne vide de même largeur ensuite.
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
                // Nom de l'auteur, cliquable, au début d'une suite.
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
                    // Message en cours d'envoi : semi-transparent.
                    .opacity(message.isPending ? 0.6 : 1)
                    // Le texte peut être sélectionné et copié.
                    .textSelection(.enabled)

                // Heure d'envoi, en français, dans le fuseau de l'appareil.
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
    /// Titre du groupe, en titre de la feuille.
    let title: String
    /// Membres, l'utilisateur en premier puis par ordre alphabétique.
    let members: [ConversationParticipant]
    /// Identifiant de l'utilisateur, marqué « (vous) » et non cliquable.
    let myId: UUID?
    /// Sourdine de l'utilisateur, écrite par la conversation (muteBinding).
    @Binding var isMuted: Bool

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Messagerie : la feuille se ferme quand sa pile change.
    @Environment(MessagingCenter.self) private var messaging
    /// Membre dont la fiche est ouverte.
    @State private var selected: ConversationParticipant?

    /// Interrupteur de sourdine, puis la liste des membres.
    var body: some View {
        NavigationStack {
            List {
                // Sourdine, pour soi seul.
                Section {
                    Toggle(isOn: $isMuted) {
                        Label("Couper les notifications", systemImage: "bell.slash")
                    }
                    .tint(Brand.navy700)
                } footer: {
                    Text("Pour vous seulement : les autres membres continuent d'être prévenus.")
                }

                // « N membres » ; un tap sur un autre membre ouvre sa fiche,
                // sa propre ligne ne fait rien.
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
