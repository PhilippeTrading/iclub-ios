//
//  MessagingCenter.swift
//  iClub
//
//  État global de la messagerie : liste des conversations, total des non-lus
//  (pour la bulle et la pastille de l'icône), feuille ouverte ou non, et
//  conversation affichée.
//
//  Unique, parce que trois endroits doivent agir sur la même feuille : la
//  bulle, les boutons « Écrire » des écrans, et le tap sur une notification.
//

import Foundation
import Observation
import Supabase
import SwiftUI
import UserNotifications

/// Une conversation poussée dans la pile de la feuille.
struct ConversationRoute: Hashable {
    let conversationId: UUID
}

/// Écran de recherche d'un membre pour écrire un nouveau message.
struct NewMessageRoute: Hashable {}

@Observable
final class MessagingCenter {

    static let shared = MessagingCenter()

    enum Availability: Equatable {
        case unknown, available
        /// La migration de la messagerie n'est pas passée.
        case unavailable
    }

    private(set) var conversations: [ConversationSummary] = []
    private(set) var availability: Availability = .unknown
    private(set) var isLoaded = false

    /// Total des non-lus, tel que la base le compte : jamais un compteur local.
    var totalUnread: Int { conversations.reduce(0) { $0 + $1.nonLus } }

    var isSheetPresented = false
    var path = NavigationPath()
    /// Conversation à l'écran : une notification qui la concerne ne s'affiche pas.
    var visibleConversationId: UUID?
    /// Erreur à montrer par-dessus l'app (ouverture d'une conversation refusée).
    var errorMessage: String?

    /// Écrans qui ont un bouton d'action principal en bas : la bulle s'efface
    /// tant qu'il y en a au moins un à l'écran.
    private(set) var bubbleHiders = 0
    var isBubbleHidden: Bool { bubbleHiders > 0 }

    private var reloadTask: Task<Void, Never>?

    /// Cours encadrés par le membre : leurs groupes, il peut les supprimer.
    private(set) var coachedActivityIds: Set<UUID> = []

    /// Groupes supprimés par l'entraîneur sur cet appareil : la synchronisation
    /// ne doit pas les recréer aussitôt.
    private static let deletedGroupsKey = "messaging.deletedGroupActivities"
    private var deletedGroupActivities: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.deletedGroupsKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.deletedGroupsKey) }
    }

    private init() {}

    // MARK: - Ouverture

    func present() {
        isSheetPresented = true
    }

    func open(conversationId: UUID) {
        var newPath = NavigationPath()
        newPath.append(ConversationRoute(conversationId: conversationId))
        path = newPath
        isSheetPresented = true
    }

    /// Conversation à deux avec un membre du club.
    func startConversation(with profileId: UUID) async {
        do {
            let id = try await MessagingService.openConversation(with: profileId)
            open(conversationId: id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Conversation du groupe d'un cours (entraîneur).
    func openGroup(activityId: UUID) async {
        do {
            let id = try await MessagingService.openGroup(activityId: activityId)
            open(conversationId: id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Groupes de cours

    /// Un groupe par cours, avec l'entraîneur et tous les inscrits.
    ///
    /// `ouvrir_conversation_activite` crée le groupe la première fois et y
    /// ajoute ensuite les nouveaux inscrits : on l'appelle pour chaque cours qui
    /// a des inscrits, à chaque ouverture de l'app par l'entraîneur.
    func syncCoachGroups(for profile: SessionProfile) async {
        guard profile.isCoach,
              let activities = try? await ActivityService.loadCoached(clubId: profile.clubId, coachId: profile.id)
        else { return }

        coachedActivityIds = Set(activities.map(\.id))
        let enrollments = (try? await ActivityService.activeEnrollments(activityIds: activities.map(\.id))) ?? []
        let withStudents = Set(enrollments.filter { $0.statut == .inscrit }.map(\.activiteId))
        let skipped = deletedGroupActivities

        for activity in activities where withStudents.contains(activity.id) && !skipped.contains(activity.id) {
            _ = try? await MessagingService.openGroup(activityId: activity.id)
        }
    }

    /// Le groupe disparaît pour tous ses membres.
    func deleteGroup(_ conversation: ConversationSummary) async {
        do {
            try await MessagingService.deleteGroup(conversation.id)
            if let activityId = conversation.activiteId {
                deletedGroupActivities.insert(activityId)
            }
            conversations.removeAll { $0.id == conversation.id }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sourdine, pour soi seul : les autres membres continuent d'être notifiés.
    func setMuted(_ muted: Bool, conversation: ConversationSummary, profileId: UUID) async {
        do {
            try await MessagingService.setMuted(muted, conversationId: conversation.id, profileId: profileId)
            await reload()
        } catch {
            errorMessage = "Les notifications de cette conversation n'ont pas pu être modifiées."
        }
    }

    func canDelete(_ conversation: ConversationSummary) -> Bool {
        guard conversation.isGroup, let activityId = conversation.activiteId else { return false }
        return coachedActivityIds.contains(activityId)
    }

    // MARK: - Bulle

    func hideBubble() { bubbleHiders += 1 }
    func showBubble() { bubbleHiders = max(0, bubbleHiders - 1) }

    // MARK: - Liste et temps réel

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    func activate() async {
        await reload()
        guard availability == .available else { return }
        await observeMessages()
    }

    func reload() async {
        do {
            conversations = try await MessagingService.myConversations()
            availability = .available
        } catch ActivityServiceError.unavailable {
            conversations = []
            availability = .unavailable
        } catch {
            // Coupure réseau : on garde la liste affichée.
        }
        isLoaded = true
        await updateAppBadge()
    }

    /// À la déconnexion : rien du compte précédent ne doit rester.
    func reset() {
        conversations = []
        coachedActivityIds = []
        availability = .unknown
        isLoaded = false
        isSheetPresented = false
        path = NavigationPath()
        visibleConversationId = nil
        Task { await updateAppBadge() }
    }

    /// Sans filtre : la base ne transmet que les messages des conversations
    /// auxquelles on participe, ce qui suffit à tenir les compteurs à jour.
    private func observeMessages() async {
        let channel = Supa.client.channel("messages-inbox")
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")

        try? await channel.subscribeWithError()
        defer { Task { await Supa.client.removeChannel(channel) } }

        for await _ in inserts {
            scheduleReload()
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Pastille de l'icône : le total renvoyé par la base.
    private func updateAppBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
    }
}

// MARK: - Masquer la bulle

extension View {
    /// À poser sur un écran dont le bouton d'action principal est en bas :
    /// la bulle de messagerie s'efface le temps de l'écran.
    func hidesMessageBubble() -> some View {
        modifier(HidesMessageBubble())
    }
}

private struct HidesMessageBubble: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { MessagingCenter.shared.hideBubble() }
            .onDisappear { MessagingCenter.shared.showBubble() }
    }
}
