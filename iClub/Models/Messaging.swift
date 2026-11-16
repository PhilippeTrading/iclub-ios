//
//  Messaging.swift
//  iClub
//
//  Messagerie entre membres d'un club : tables `conversations`,
//  `conversation_participants`, `messages`. Les membres ne la consultent que
//  dans l'app iOS ; le back-office web y dépose seulement des messages (repli
//  d'un cours en salle pour cause de pluie, `src/lib/actions/pluie.ts`).
//
//  Rôle
//    Lignes décodées des fonctions SQL `mes_conversations()` et
//    `participants_conversation()`, et des messages lus en base ou reçus en
//    temps réel (migration `20261023100000_messagerie.sql`).
//
//  Place dans l'application
//    `MessagingService` les produit ; `MessagingCenter`, la liste des
//    conversations et l'écran de conversation les affichent.
//
//  Droits et sécurité
//    Les deux fonctions sont `security definer` et ne rendent que les
//    conversations de l'appelant. Les messages ne sont lisibles que par les
//    participants de leur conversation (RLS `messages_lecture`, fonction
//    `participe_a`).
//

import Foundation

/// Une ligne de `mes_conversations()`.
nonisolated struct ConversationSummary: Identifiable, Hashable, Sendable, Decodable {
    /// `conversation_id`.
    let id: UUID
    /// Titre d'un groupe ; `nil` pour une conversation à deux.
    let titre: String?
    /// `activite_id` : cours auquel le groupe est rattaché, `nil` sinon.
    let activiteId: UUID?
    /// `autre_profile_id` : l'autre personne d'une conversation à deux ; `nil`
    /// pour un groupe.
    let autreProfileId: UUID?
    /// `autre_nom` : prénom et nom de l'autre personne.
    let autreNom: String?
    /// `autre_avatar_url` : sa photo.
    let autreAvatarUrl: URL?
    /// `dernier_message` : texte du dernier message.
    let dernierMessage: String?
    /// `dernier_message_le` : date du dernier message (`timestamptz`).
    let dernierMessageLe: Date?
    /// `non_lus` : messages des autres postérieurs à ma dernière lecture
    /// (`lu_jusqu_a`). 0 à défaut.
    let nonLus: Int
    /// `silencieux` : sourdine (les messages arrivent, la notification ne part
    /// pas). Faux à défaut.
    let silencieux: Bool

    /// Titre affiché : celui du groupe, sinon le nom de l'autre personne,
    /// sinon « Conversation ».
    var displayTitle: String {
        if let titre, !titre.isEmpty { return titre }
        return autreNom ?? "Conversation"
    }

    /// Conversation de groupe (elle a un titre).
    var isGroup: Bool { titre != nil }

    /// Initiales des deux premiers mots du titre affiché, « ? » à défaut.
    var initials: String {
        let words = displayTitle.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    /// Correspondance avec les colonnes rendues par la fonction.
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

    /// Décodage tolérant : seul l'identifiant est obligatoire ; l'URL et la
    /// date arrivent en texte et sont converties ici.
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
///
/// La fonction rend aussi `lu_jusqu_a`, non décodé ici.
nonisolated struct ConversationParticipant: Identifiable, Hashable, Sendable, Decodable {
    /// `profile_id`.
    let profileId: UUID
    /// `nom_affiche` : prénom et nom, « Membre » à défaut (la fonction applique
    /// déjà ce repli).
    let nomAffiche: String
    /// `avatar_url`.
    let avatarUrl: URL?

    /// Identifiant de liste : le profil.
    var id: UUID { profileId }

    /// Premier mot du nom affiché.
    var firstName: String {
        nomAffiche.split(separator: " ").first.map(String.init) ?? nomAffiche
    }

    /// Initiales des deux premiers mots du nom, « ? » à défaut.
    var initials: String {
        let value = nomAffiche.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    /// Correspondance avec les colonnes rendues par la fonction.
    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case avatarUrl = "avatar_url"
    }

    /// Décodage tolérant : seul le profil est obligatoire.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        nomAffiche = try c.decodeIfPresent(String.self, forKey: .nomAffiche) ?? "Membre"
        avatarUrl = (try c.decodeIfPresent(String.self, forKey: .avatarUrl)).flatMap(URL.init(string:))
    }
}

/// Un message. Lu en base, ou reçu en temps réel (même forme de ligne).
nonisolated struct ChatMessage: Identifiable, Hashable, Sendable, Decodable {
    /// `messages.id` (ou identifiant provisoire d'un message en cours d'envoi).
    let id: UUID
    /// `conversation_id`.
    let conversationId: UUID
    /// `auteur_profile_id` : auteur du message.
    let auteurProfileId: UUID
    /// `corps` : texte, de 1 à 4 000 caractères hors espaces de bord
    /// (contrainte `check` de la colonne).
    let corps: String
    /// `created_at` (`timestamptz`) ; maintenant si la date est illisible.
    let createdAt: Date
    /// Vrai pour un message affiché avant la réponse de la base.
    var isPending = false

    /// Colonnes demandées à la table `messages`.
    static let columns = "id, conversation_id, auteur_profile_id, corps, created_at"

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, corps
        case conversationId = "conversation_id"
        case auteurProfileId = "auteur_profile_id"
        case createdAt = "created_at"
    }

    /// Construction locale, pour un message affiché avant confirmation de la
    /// base (envoi optimiste).
    ///
    /// - Parameters:
    ///   - id: identifiant (provisoire, ou celui rendu par `envoyer_message`).
    ///   - conversationId: conversation.
    ///   - auteurProfileId: auteur (le compte connecté).
    ///   - corps: texte.
    ///   - createdAt: date d'affichage.
    ///   - isPending: `true` tant que la base n'a pas répondu.
    init(id: UUID, conversationId: UUID, auteurProfileId: UUID, corps: String, createdAt: Date, isPending: Bool) {
        self.id = id
        self.conversationId = conversationId
        self.auteurProfileId = auteurProfileId
        self.corps = corps
        self.createdAt = createdAt
        self.isPending = isPending
    }

    /// Décodage d'une ligne de `messages`. Identifiants et texte obligatoires ;
    /// `isPending` vaut faux.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationId = try c.decode(UUID.self, forKey: .conversationId)
        auteurProfileId = try c.decode(UUID.self, forKey: .auteurProfileId)
        corps = try c.decode(String.self, forKey: .corps)
        createdAt = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .createdAt)) ?? .now
    }
}
