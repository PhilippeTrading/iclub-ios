//
//  Messaging.swift
//  iClub
//
//  Messagerie entre membres d'un club : tables `conversations`,
//  `conversation_participants`, `messages`. Elle n'existe que dans l'app iOS.
//

import Foundation

/// Une ligne de `mes_conversations()`.
nonisolated struct ConversationSummary: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    /// Titre d'un groupe ; `nil` pour une conversation à deux.
    let titre: String?
    let activiteId: UUID?
    let autreProfileId: UUID?
    let autreNom: String?
    let autreAvatarUrl: URL?
    let dernierMessage: String?
    let dernierMessageLe: Date?
    let nonLus: Int
    let silencieux: Bool

    var displayTitle: String {
        if let titre, !titre.isEmpty { return titre }
        return autreNom ?? "Conversation"
    }

    var isGroup: Bool { titre != nil }

    var initials: String {
        let words = displayTitle.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    enum CodingKeys: String, CodingKey {
        case titre, silencieux
        case id = "conversation_id"
        case activiteId = "activite_id"
        case autreProfileId = "autre_profile_id"
        case autreNom = "autre_nom"
        case autreAvatarUrl = "autre_avatar_url"
        case dernierMessage = "dernier_message"
        case dernierMessageLe = "dernier_message_le"
        case nonLus = "non_lus"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        titre = try c.decodeIfPresent(String.self, forKey: .titre)
        activiteId = try c.decodeIfPresent(UUID.self, forKey: .activiteId)
        autreProfileId = try c.decodeIfPresent(UUID.self, forKey: .autreProfileId)
        autreNom = try c.decodeIfPresent(String.self, forKey: .autreNom)
        autreAvatarUrl = (try c.decodeIfPresent(String.self, forKey: .autreAvatarUrl)).flatMap(URL.init(string:))
        dernierMessage = try c.decodeIfPresent(String.self, forKey: .dernierMessage)
        dernierMessageLe = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .dernierMessageLe))
        nonLus = try c.decodeIfPresent(Int.self, forKey: .nonLus) ?? 0
        silencieux = try c.decodeIfPresent(Bool.self, forKey: .silencieux) ?? false
    }
}

/// Une ligne de `participants_conversation()`.
nonisolated struct ConversationParticipant: Identifiable, Hashable, Sendable, Decodable {
    let profileId: UUID
    let nomAffiche: String
    let avatarUrl: URL?

    var id: UUID { profileId }

    var firstName: String {
        nomAffiche.split(separator: " ").first.map(String.init) ?? nomAffiche
    }

    var initials: String {
        let value = nomAffiche.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case avatarUrl = "avatar_url"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        nomAffiche = try c.decodeIfPresent(String.self, forKey: .nomAffiche) ?? "Membre"
        avatarUrl = (try c.decodeIfPresent(String.self, forKey: .avatarUrl)).flatMap(URL.init(string:))
    }
}

/// Un message. Lu en base, ou reçu en temps réel (même forme de ligne).
nonisolated struct ChatMessage: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let conversationId: UUID
    let auteurProfileId: UUID
    let corps: String
    let createdAt: Date
    /// Vrai pour un message affiché avant la réponse de la base.
    var isPending = false

    static let columns = "id, conversation_id, auteur_profile_id, corps, created_at"

    enum CodingKeys: String, CodingKey {
        case id, corps
        case conversationId = "conversation_id"
        case auteurProfileId = "auteur_profile_id"
        case createdAt = "created_at"
    }

    init(id: UUID, conversationId: UUID, auteurProfileId: UUID, corps: String, createdAt: Date, isPending: Bool) {
        self.id = id
        self.conversationId = conversationId
        self.auteurProfileId = auteurProfileId
        self.corps = corps
        self.createdAt = createdAt
        self.isPending = isPending
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationId = try c.decode(UUID.self, forKey: .conversationId)
        auteurProfileId = try c.decode(UUID.self, forKey: .auteurProfileId)
        corps = try c.decode(String.self, forKey: .corps)
        createdAt = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .createdAt)) ?? .now
    }
}
