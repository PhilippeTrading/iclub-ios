//
//  MessagingService.swift
//  iClub
//
//  Appels de la messagerie. Toutes les créations passent par des fonctions de
//  la base : elles garantissent qu'on n'écrit qu'aux membres de son club, et
//  qu'on ne lit que les conversations auxquelles on participe.
//

import Foundation
import Supabase

enum MessagingService {

    static let maxLength = 4_000
    static let pageSize = 50

    static func myConversations() async throws -> [ConversationSummary] {
        do {
            let rows: [Lenient<ConversationSummary>] = try await Supa.client
                .rpc("mes_conversations")
                .execute()
                .value
            return rows.compactValues()
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    static func participants(of conversationId: UUID) async throws -> [ConversationParticipant] {
        let rows: [Lenient<ConversationParticipant>] = try await Supa.client
            .rpc("participants_conversation", params: ConversationParam(id: conversationId))
            .execute()
            .value
        return rows.compactValues()
    }

    /// Une page de messages, du plus ancien au plus récent. `before` remonte
    /// dans l'historique.
    static func messages(in conversationId: UUID, before: Date? = nil) async throws -> [ChatMessage] {
        var query = Supa.client
            .from("messages")
            .select(ChatMessage.columns)
            .eq("conversation_id", value: conversationId.uuidString)

        if let before {
            query = query.lt("created_at", value: before.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true)))
        }

        let page: [ChatMessage] = try await query
            .order("created_at", ascending: false)
            .limit(pageSize)
            .execute()
            .value
        return page.reversed()
    }

    static func send(_ body: String, to conversationId: UUID) async throws -> UUID {
        do {
            return try await Supa.client
                .rpc("envoyer_message", params: SendParams(conversationId: conversationId, corps: body))
                .execute()
                .value
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    static func markRead(_ conversationId: UUID) async {
        _ = try? await Supa.client
            .rpc("marquer_conversation_lue", params: ConversationParam(id: conversationId))
            .execute()
    }

    /// Sourdine : seule sa propre ligne de participant est modifiable.
    static func setMuted(_ muted: Bool, conversationId: UUID, profileId: UUID) async throws {
        let rows: [MutedRow] = try await Supa.client
            .from("conversation_participants")
            .update(MutedRow(silencieux: muted))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("profile_id", value: profileId.uuidString)
            .select("silencieux")
            .execute()
            .value
        guard !rows.isEmpty else { throw ActivityServiceError.refused("Réglage non enregistré.") }
    }

    /// Conversation à deux, créée ou retrouvée.
    static func openConversation(with profileId: UUID) async throws -> UUID {
        do {
            return try await Supa.client
                .rpc("ouvrir_conversation", params: WithParam(profileId: profileId))
                .execute()
                .value
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    /// Groupe d'un cours. À rappeler à chaque ouverture : la fonction y ajoute
    /// les inscrits arrivés depuis.
    static func openGroup(activityId: UUID) async throws -> UUID {
        do {
            return try await Supa.client
                .rpc("ouvrir_conversation_activite", params: ActivityParam(activityId: activityId))
                .execute()
                .value
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    /// Supprime un groupe de cours pour tous ses membres. Réservé à
    /// l'entraîneur du cours (ou à l'administration) : c'est la base qui le
    /// vérifie, par `supprimer_conversation`.
    static func deleteGroup(_ conversationId: UUID) async throws {
        do {
            try await Supa.client
                .rpc("supprimer_conversation", params: ConversationParam(id: conversationId))
                .execute()
        } catch {
            let mapped = ActivityServiceError.from(error)
            if case .unavailable = mapped {
                throw ActivityServiceError.refused("La suppression d'un groupe n'est pas encore disponible pour votre club.")
            }
            throw mapped
        }
    }

    // MARK: - Paramètres

    private nonisolated struct ConversationParam: Encodable, Sendable {
        let id: UUID
        enum CodingKeys: String, CodingKey { case id = "p_conversation_id" }
    }

    private nonisolated struct SendParams: Encodable, Sendable {
        let conversationId: UUID
        let corps: String
        enum CodingKeys: String, CodingKey {
            case conversationId = "p_conversation_id"
            case corps = "p_corps"
        }
    }

    private nonisolated struct WithParam: Encodable, Sendable {
        let profileId: UUID
        enum CodingKeys: String, CodingKey { case profileId = "p_avec_profile_id" }
    }

    private nonisolated struct ActivityParam: Encodable, Sendable {
        let activityId: UUID
        enum CodingKeys: String, CodingKey { case activityId = "p_activite_id" }
    }

    private nonisolated struct MutedRow: Codable, Sendable {
        let silencieux: Bool
    }
}
