//
//  MessagingService.swift
//  iClub
//
//  Appels de la messagerie. Toutes les créations passent par des fonctions de
//  la base : elles garantissent qu'on n'écrit qu'aux membres de son club, et
//  qu'on ne lit que les conversations auxquelles on participe.
//
//  Place dans l'application
//    `MessagingCenter` (liste, bulle, ouverture d'une conversation ou d'un
//    groupe de cours, suppression d'un groupe) et `ConversationView` (messages,
//    envoi, lecture, sourdine).
//
//  Tables et fonctions SQL (migration `20261023100000_messagerie.sql`)
//    - Lecture : `mes_conversations()`, `participants_conversation(p_conversation_id)`,
//      table `messages` (RLS : participants seulement, via `participe_a`).
//    - Écriture : `envoyer_message`, `marquer_conversation_lue`,
//      `ouvrir_conversation`, `ouvrir_conversation_activite`, et la table
//      `conversation_participants` pour la sourdine (RLS : sa propre ligne).
//    - `supprimer_conversation` : appelée mais absente des migrations du dépôt
//      web ; l'app affiche alors que la suppression n'est pas disponible.
//
//  Effets de bord
//    Chaque message inséré déclenche, côté serveur, un webhook Supabase qui
//    appelle la fonction `push-message` : notification APNs aux autres
//    participants, sauf à ceux qui ont mis la conversation en sourdine.
//
//  Gestion des erreurs
//    La plupart des erreurs sont traduites par `ActivityServiceError.from`
//    (refus rédigé de la base, fonction absente, échec générique).
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Le temps réel (insertions dans `messages`) est écouté par
//    `MessagingCenter`, pas ici.
//

import Foundation
import Supabase

/// Accès à la messagerie entre membres.
enum MessagingService {

    /// Longueur maximale d'un message, la même que la contrainte `check` de
    /// `messages.corps` (1 à 4 000 caractères hors espaces de bord).
    static let maxLength = 4_000
    /// Nombre de messages chargés par page d'historique.
    static let pageSize = 50

    /// Conversations du membre connecté, de la plus récemment active à la plus
    /// ancienne, avec le dernier message et le nombre de non-lus.
    ///
    /// - Returns: une ligne par conversation ; une ligne illisible est écartée.
    /// - Throws: `ActivityServiceError` (fonction absente, échec).
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

    /// Participants d'une conversation, avec nom et photo (la fiche d'un autre
    /// membre n'est pas lisible directement).
    ///
    /// - Parameter conversationId: conversation affichée.
    /// - Returns: les participants ; vide si l'appelant n'en fait pas partie.
    /// - Throws: l'erreur brute de la requête.
    static func participants(of conversationId: UUID) async throws -> [ConversationParticipant] {
        let rows: [Lenient<ConversationParticipant>] = try await Supa.client
            .rpc("participants_conversation", params: ConversationParam(id: conversationId))
            .execute()
            .value
        return rows.compactValues()
    }

    /// Une page de messages, du plus ancien au plus récent. `before` remonte
    /// dans l'historique.
    ///
    /// - Parameters:
    ///   - conversationId: conversation affichée.
    ///   - before: date du plus ancien message déjà affiché ; `nil` pour la
    ///     page la plus récente.
    /// - Returns: au plus `pageSize` messages, dans l'ordre chronologique.
    /// - Throws: l'erreur brute de la requête.
    static func messages(in conversationId: UUID, before: Date? = nil) async throws -> [ChatMessage] {
        var query = Supa.client
            .from("messages")
            .select(ChatMessage.columns)
            .eq("conversation_id", value: conversationId.uuidString)

        // Pagination par date : messages strictement plus anciens que le
        // premier affiché (ISO 8601 avec fuseau et fractions de seconde).
        if let before {
            query = query.lt("created_at", value: before.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true)))
        }

        // Les plus récents d'abord pour prendre les `pageSize` derniers, puis
        // retournés pour l'affichage chronologique.
        let page: [ChatMessage] = try await query
            .order("created_at", ascending: false)
            .limit(pageSize)
            .execute()
            .value
        return page.reversed()
    }

    /// Envoie un message (fonction `envoyer_message`).
    ///
    /// La fonction vérifie que l'appelant participe à la conversation, refuse un
    /// message vide, retire les espaces de bord, met à jour la date du dernier
    /// message et marque la conversation lue pour l'auteur.
    ///
    /// - Parameters:
    ///   - body: texte saisi.
    ///   - conversationId: conversation visée.
    /// - Returns: l'identifiant du message créé.
    /// - Throws: `ActivityServiceError` (refus rédigé de la base, échec).
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

    /// Marque la conversation lue jusqu'à maintenant (`lu_jusqu_a = now()` sur
    /// sa propre ligne de participant). Une erreur est ignorée : au pire, le
    /// compteur de non-lus reste affiché.
    ///
    /// - Parameter conversationId: conversation affichée.
    static func markRead(_ conversationId: UUID) async {
        _ = try? await Supa.client
            .rpc("marquer_conversation_lue", params: ConversationParam(id: conversationId))
            .execute()
    }

    /// Sourdine : seule sa propre ligne de participant est modifiable.
    ///
    /// - Parameters:
    ///   - muted: `true` pour couper les notifications de cette conversation.
    ///   - conversationId: conversation concernée.
    ///   - profileId: profil du membre connecté (la RLS `participants_maj`
    ///     refuse toute autre ligne).
    /// - Throws: `ActivityServiceError.refused` si aucune ligne n'a été
    ///   modifiée ; l'erreur brute de la requête sinon.
    static func setMuted(_ muted: Bool, conversationId: UUID, profileId: UUID) async throws {
        // `.select` après la mise à jour : une écriture refusée par la RLS ne
        // lève pas d'erreur, elle ne touche aucune ligne et rend une liste vide.
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
    ///
    /// La fonction `ouvrir_conversation` refuse de s'écrire à soi-même et
    /// d'écrire à quelqu'un qui n'est pas membre d'un club commun ; elle rend
    /// la conversation à deux existante si elle existe déjà.
    ///
    /// - Parameter profileId: l'autre membre.
    /// - Returns: identifiant de la conversation.
    /// - Throws: `ActivityServiceError` (refus rédigé de la base, échec).
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
    ///
    /// Réservé à l'entraîneur de l'activité ou à l'administration (refus
    /// « Réservé à l'entraîneur de ce cours »). Le groupe réunit l'entraîneur,
    /// les inscrits (statut `inscrit`) et les parents des enfants inscrits.
    ///
    /// - Parameter activityId: cours concerné.
    /// - Returns: identifiant de la conversation de groupe.
    /// - Throws: `ActivityServiceError` (refus, échec).
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
    ///
    /// Limite connue : `supprimer_conversation` n'existe dans aucune migration
    /// du dépôt web ; tant qu'elle n'est pas créée, l'appel rend « fonction
    /// absente » et l'app affiche le message d'indisponibilité ci-dessous.
    ///
    /// - Parameter conversationId: groupe à supprimer.
    /// - Throws: `ActivityServiceError.refused` (indisponible, ou refus de la
    ///   base) ou `.failed`.
    static func deleteGroup(_ conversationId: UUID) async throws {
        do {
            try await Supa.client
                .rpc("supprimer_conversation", params: ConversationParam(id: conversationId))
                .execute()
        } catch {
            let mapped = ActivityServiceError.from(error)
            // Fonction absente : message propre à cette action plutôt que le
            // texte générique d'indisponibilité.
            if case .unavailable = mapped {
                throw ActivityServiceError.refused("La suppression d'un groupe n'est pas encore disponible pour votre club.")
            }
            throw mapped
        }
    }

    // MARK: - Paramètres

    /// Paramètre `p_conversation_id` des fonctions de conversation.
    private nonisolated struct ConversationParam: Encodable, Sendable {
        /// Conversation visée.
        let id: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case id = "p_conversation_id" }
    }

    /// Paramètres de `envoyer_message`.
    private nonisolated struct SendParams: Encodable, Sendable {
        /// `p_conversation_id`.
        let conversationId: UUID
        /// `p_corps` : texte du message.
        let corps: String
        /// Noms des paramètres SQL.
        enum CodingKeys: String, CodingKey {
            case conversationId = "p_conversation_id"
            case corps = "p_corps"
        }
    }

    /// Paramètre de `ouvrir_conversation`.
    private nonisolated struct WithParam: Encodable, Sendable {
        /// `p_avec_profile_id` : l'autre membre.
        let profileId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case profileId = "p_avec_profile_id" }
    }

    /// Paramètre de `ouvrir_conversation_activite`.
    private nonisolated struct ActivityParam: Encodable, Sendable {
        /// `p_activite_id` : le cours.
        let activityId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case activityId = "p_activite_id" }
    }

    /// Mise à jour et relecture de la colonne `silencieux`.
    private nonisolated struct MutedRow: Codable, Sendable {
        /// `conversation_participants.silencieux`.
        let silencieux: Bool
    }
}
