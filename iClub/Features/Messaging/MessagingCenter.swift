//
//  MessagingCenter.swift
//  iClub
//
//  Rôle
//    État global de la messagerie : liste des conversations, total des non-lus
//    (pour la bulle et la pastille de l'icône), feuille ouverte ou non, et
//    conversation affichée.
//
//    Unique, parce que trois endroits doivent agir sur la même feuille : la
//    bulle, les boutons « Écrire » des écrans, et le tap sur une notification.
//
//  Place dans l'application
//    `MessagingCenter.shared` est injecté dans l'environnement par iClubApp.
//    MainTabView dessine la bulle flottante, présente la feuille
//    (MessagesSheet) quand `isSheetPresented` passe à vrai, affiche
//    `errorMessage` en alerte « Messagerie », et appelle `syncCoachGroups`,
//    puis `activate()` à l'ouverture de la session. PushService appelle
//    `open(conversationId:)` au tap sur une notification de message, et lit
//    `visibleConversationId` pour ne pas afficher la notification d'une
//    conversation déjà à l'écran. AuthService appelle `reset()` à la
//    déconnexion et à la suppression du compte.
//
//  Données (MessagingService, fonctions SQL de la migration
//  20261023100000_messagerie)
//    `mes_conversations` (liste et non-lus), `ouvrir_conversation` (à deux),
//    `ouvrir_conversation_activite` (groupe d'un cours), mise à jour de
//    `conversation_participants.silencieux` (sourdine), et
//    `supprimer_conversation` (suppression d'un groupe). Temps réel Supabase
//    sur les insertions de la table `messages`.
//
//  Droits et sécurité
//    La base ne montre que les conversations auxquelles on participe
//    (fonction `participe_a`, RLS des trois tables) ; on n'écrit qu'aux
//    membres de son club ; seul l'entraîneur du cours (ou un administrateur)
//    ouvre le groupe d'un cours. Les notifications push des messages partent
//    hors de l'app (webhook sur `messages` vers la fonction Edge
//    `push-message` du dépôt web).
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage du projet).
//    L'écoute du temps réel est une boucle `for await` qui vit autant que la
//    tâche appelante (le `.task` de MainTabView).
//
//  Points d'attention
//    - Limite connue : aucune migration du dépôt web ne crée la fonction
//      `supprimer_conversation` (à la date de cette passe). La suppression
//      d'un groupe échoue donc avec « La suppression d'un groupe n'est pas
//      encore disponible pour votre club. »
//    - Le total des non-lus compte aussi les conversations mises en sourdine.
//    - La liste des groupes supprimés est gardée dans UserDefaults pour
//      l'appareil, pas pour le compte, et n'est pas effacée par `reset()`.
//

import Foundation
import Observation
import Supabase
import SwiftUI
import UserNotifications

/// Une conversation poussée dans la pile de la feuille.
struct ConversationRoute: Hashable {
    /// Identifiant de la conversation (`conversations.id`).
    let conversationId: UUID
}

/// Écran de recherche d'un membre pour écrire un nouveau message.
struct NewMessageRoute: Hashable {}

/// État partagé de la messagerie, unique pour toute l'app.
@Observable
final class MessagingCenter {

    /// L'instance unique, injectée dans l'environnement par iClubApp.
    static let shared = MessagingCenter()

    /// La messagerie est-elle déployée dans la base du club ?
    enum Availability: Equatable {
        /// unknown : pas encore de réponse ; available : `mes_conversations`
        /// a répondu.
        case unknown, available
        /// La migration de la messagerie n'est pas passée.
        case unavailable
    }

    /// Conversations de l'utilisateur, dans l'ordre de `mes_conversations` (la
    /// plus récemment active d'abord).
    private(set) var conversations: [ConversationSummary] = []
    /// Disponibilité de la messagerie.
    private(set) var availability: Availability = .unknown
    /// Au moins un chargement a abouti ou échoué.
    private(set) var isLoaded = false

    /// Total des non-lus, tel que la base le compte : jamais un compteur local.
    var totalUnread: Int { conversations.reduce(0) { $0 + $1.nonLus } }

    /// La feuille de messagerie est ouverte (liée à `.sheet` de MainTabView).
    var isSheetPresented = false
    /// Pile de navigation de la feuille : liste, puis conversation ou nouveau
    /// message.
    var path = NavigationPath()
    /// Conversation à l'écran : une notification qui la concerne ne s'affiche pas.
    var visibleConversationId: UUID?
    /// Erreur à montrer par-dessus l'app (ouverture d'une conversation refusée).
    var errorMessage: String?

    /// Écrans qui ont un bouton d'action principal en bas : la bulle s'efface
    /// tant qu'il y en a au moins un à l'écran.
    private(set) var bubbleHiders = 0
    /// Vrai tant qu'au moins un écran demande à masquer la bulle.
    var isBubbleHidden: Bool { bubbleHiders > 0 }

    /// Rechargement différé en attente, annulé à chaque nouvel événement.
    private var reloadTask: Task<Void, Never>?

    /// Cours encadrés par le membre : leurs groupes, il peut les supprimer.
    private(set) var coachedActivityIds: Set<UUID> = []

    /// Groupes supprimés par l'entraîneur sur cet appareil : la synchronisation
    /// ne doit pas les recréer aussitôt.
    ///
    /// Identifiants des cours (pas des conversations), rangés dans
    /// UserDefaults sous cette clé.
    private static let deletedGroupsKey = "messaging.deletedGroupActivities"
    /// Lecture et écriture de cette liste dans UserDefaults ; un identifiant
    /// illisible est ignoré.
    private var deletedGroupActivities: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.deletedGroupsKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.deletedGroupsKey) }
    }

    /// Privé : on passe toujours par `shared`.
    private init() {}

    // MARK: - Ouverture

    /// Ouvre la feuille là où sa pile en est (la liste, après une fermeture).
    func present() {
        isSheetPresented = true
    }

    /// Ouvre la feuille directement sur une conversation, en remplaçant la
    /// pile (liste en dessous, pour le retour).
    /// - Parameter conversationId: identifiant de la conversation.
    func open(conversationId: UUID) {
        var newPath = NavigationPath()
        newPath.append(ConversationRoute(conversationId: conversationId))
        path = newPath
        isSheetPresented = true
    }

    /// Conversation à deux avec un membre du club.
    ///
    /// `ouvrir_conversation` retrouve la conversation existante ou la crée ;
    /// elle refuse d'écrire à soi-même ou à quelqu'un d'un autre club. Un refus
    /// passe dans `errorMessage`.
    /// - Parameter profileId: identifiant du profil du destinataire.
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
    ///
    /// `ouvrir_conversation_activite` crée le groupe au nom du cours la
    /// première fois, puis y ajoute l'entraîneur, les inscrits qui ont un
    /// compte et les responsables des enfants inscrits. Un refus passe dans
    /// `errorMessage`.
    /// - Parameter activityId: identifiant du cours.
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
    ///
    /// Sans effet pour un profil qui n'est pas entraîneur. Les échecs sont
    /// ignorés un par un : un groupe non synchronisé le sera à la prochaine
    /// ouverture.
    /// - Parameter profile: profil de la session.
    func syncCoachGroups(for profile: SessionProfile) async {
        guard profile.isCoach,
              let activities = try? await ActivityService.loadCoached(clubId: profile.clubId, coachId: profile.id)
        else { return }

        // Cours encadrés : ils autorisent la suppression de leur groupe.
        coachedActivityIds = Set(activities.map(\.id))
        // Cours qui ont au moins un inscrit (la liste d'attente ne compte pas).
        let enrollments = (try? await ActivityService.activeEnrollments(activityIds: activities.map(\.id))) ?? []
        let withStudents = Set(enrollments.filter { $0.statut == .inscrit }.map(\.activiteId))
        // Groupes supprimés depuis cet appareil : on ne les recrée pas.
        let skipped = deletedGroupActivities

        for activity in activities where withStudents.contains(activity.id) && !skipped.contains(activity.id) {
            _ = try? await MessagingService.openGroup(activityId: activity.id)
        }
    }

    /// Le groupe disparaît pour tous ses membres.
    ///
    /// Le cours est noté dans la liste des groupes supprimés de l'appareil, la
    /// conversation retirée de la liste tout de suite, puis la liste relue. Un
    /// échec passe dans `errorMessage` (voir la limite connue en tête de
    /// fichier).
    /// - Parameter conversation: le groupe à supprimer.
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
    ///
    /// Écrit `silencieux` sur sa propre ligne de `conversation_participants`
    /// (la RLS « participants_maj » n'autorise que celle-là), puis relit la
    /// liste. La fonction Edge `push-message` n'envoie rien aux participants
    /// en sourdine.
    /// - Parameters:
    ///   - muted: vrai pour couper les notifications.
    ///   - conversation: la conversation.
    ///   - profileId: profil de l'utilisateur connecté.
    func setMuted(_ muted: Bool, conversation: ConversationSummary, profileId: UUID) async {
        do {
            try await MessagingService.setMuted(muted, conversationId: conversation.id, profileId: profileId)
            await reload()
        } catch {
            errorMessage = "Les notifications de cette conversation n'ont pas pu être modifiées."
        }
    }

    /// L'utilisateur peut-il supprimer cette conversation ?
    /// - Parameter conversation: la conversation.
    /// - Returns: vrai pour le groupe d'un cours qu'il encadre (d'après la
    ///   dernière synchronisation) ; la base revérifierait le droit.
    func canDelete(_ conversation: ConversationSummary) -> Bool {
        guard conversation.isGroup, let activityId = conversation.activiteId else { return false }
        return coachedActivityIds.contains(activityId)
    }

    // MARK: - Bulle

    /// Un écran de plus demande à masquer la bulle.
    func hideBubble() { bubbleHiders += 1 }
    /// Un écran de moins ; le compteur ne descend jamais sous zéro.
    func showBubble() { bubbleHiders = max(0, bubbleHiders - 1) }

    // MARK: - Liste et temps réel

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    ///
    /// Si la messagerie n'est pas disponible (migration absente), aucune
    /// écoute n'est ouverte.
    func activate() async {
        await reload()
        guard availability == .available else { return }
        await observeMessages()
    }

    /// Relit la liste des conversations et met à jour la pastille de l'icône.
    ///
    /// Fonction absente en base : liste vidée et messagerie marquée
    /// indisponible. Autre erreur (réseau) : la liste affichée est gardée.
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
    ///
    /// Vide la liste, ferme la feuille, remet la pile à zéro et la pastille de
    /// l'icône à zéro (la liste étant vide).
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
    ///
    /// Abonnement Realtime aux insertions de `messages` (table ajoutée à la
    /// publication `supabase_realtime` par la migration) ; la RLS
    /// « messages_lecture » filtre les lignes reçues. Chaque insertion
    /// déclenche un rechargement différé. Le canal est retiré quand la boucle
    /// s'arrête (annulation de la tâche).
    private func observeMessages() async {
        let channel = Supa.client.channel("messages-inbox")
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")

        // Un échec d'abonnement est ignoré : la liste se rafraîchit encore à
        // l'ouverture de la feuille et après chaque envoi.
        try? await channel.subscribeWithError()
        defer { Task { await Supa.client.removeChannel(channel) } }

        for await _ in inserts {
            scheduleReload()
        }
    }

    /// Regroupe une rafale de messages en un seul rechargement, 300 ms après
    /// le dernier.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Pastille de l'icône : le total renvoyé par la base.
    ///
    /// Un échec (autorisation refusée) est ignoré.
    private func updateAppBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
    }
}

// MARK: - Masquer la bulle

/// Masquage de la bulle de messagerie, applicable à tout écran.
extension View {
    /// À poser sur un écran dont le bouton d'action principal est en bas :
    /// la bulle de messagerie s'efface le temps de l'écran.
    /// - Returns: la vue, qui masque la bulle à son apparition et la rend à
    ///   sa disparition.
    func hidesMessageBubble() -> some View {
        modifier(HidesMessageBubble())
    }
}

/// Modificateur qui compte l'écran parmi ceux qui masquent la bulle, le temps
/// de son affichage.
private struct HidesMessageBubble: ViewModifier {
    /// Le contenu, avec l'incrément à l'apparition et le décrément à la
    /// disparition.
    /// - Parameter content: l'écran.
    /// - Returns: l'écran inchangé à l'œil.
    func body(content: Content) -> some View {
        content
            .onAppear { MessagingCenter.shared.hideBubble() }
            .onDisappear { MessagingCenter.shared.showBubble() }
    }
}
