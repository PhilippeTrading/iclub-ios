//
//  ClubContent.swift
//  iClub
//
//  Annonces et activités du club, telles que l'admin les publie depuis le
//  back-office web.
//
//  Rôle
//    Lignes décodées de `annonces` et de la forme historique de `activites`
//    (horaire hebdomadaire en texte), et types du domaine affichés par
//    l'accueil.
//
//  Place dans l'application
//    `ClubContentService` les lit ; l'accueil (`HomeStore`, `HomeView`) et
//    l'historique des notifications (`NotificationHistory`, annonces) les
//    affichent. Les cours détaillés (inscriptions, séances) passent par
//    Activity.swift et `ActivityService`.
//
//  Droits et sécurité
//    Lecture par les membres du club (RLS `annonces_select_club`,
//    `activites_select_club`) ; écriture par l'administration.
//

import Foundation
import SwiftUI

// MARK: - Annonces

/// Niveau d'une annonce (`annonces.niveau`, contrainte `check` sur ces trois
/// valeurs).
nonisolated enum AnnouncementLevel: String, Sendable {
    /// Cas courant, badge neutre.
    case information
    /// À lire, badge orangé.
    case important
    /// Urgent, badge rouge.
    case urgent

    /// Libellé du badge.
    var displayName: String {
        switch self {
        case .information: "Information"
        case .important: "Important"
        case .urgent: "Urgent"
        }
    }
}

/// Ligne de `annonces`.
nonisolated struct AnnouncementRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `niveau`, valeur brute.
    let niveau: String?
    /// `titre`.
    let titre: String?
    /// `corps` : texte de l'annonce.
    let corps: String?
    /// `created_at` (`timestamptz`), en texte.
    let createdAt: String?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, niveau, titre, corps
        case createdAt = "created_at"
    }

    /// Colonnes demandées ; `actif` sert au filtre de la requête et n'est pas
    /// décodé.
    static let columns = "id, niveau, titre, corps, actif, created_at"

    /// Conversion vers le type du domaine.
    ///
    /// - Returns: `nil` pour une annonce sans titre. Un niveau inconnu devient
    ///   « Information » ; un corps absent, une chaîne vide.
    func toDomain() -> Announcement? {
        guard let titre, !titre.isEmpty else { return nil }
        return Announcement(
            id: id,
            level: niveau.flatMap { AnnouncementLevel(rawValue: $0.lowercased()) } ?? .information,
            title: titre,
            body: corps ?? "",
            createdAt: SupabaseDate.parse(createdAt)
        )
    }
}

/// Annonce prête à afficher.
nonisolated struct Announcement: Identifiable, Hashable, Sendable {
    /// `annonces.id`.
    let id: UUID
    /// Niveau, pour la couleur du badge.
    let level: AnnouncementLevel
    /// Titre.
    let title: String
    /// Texte.
    let body: String
    /// Date de publication, `nil` si illisible.
    var createdAt: Date?
}

/// Couleur du niveau, séparée du type : elle dépend de la charte (`Brand`),
/// isolée sur l'acteur principal, alors que le type est `nonisolated`.
extension AnnouncementLevel {
    /// Teinte du badge. « Information » reste neutre : c'est le cas courant,
    /// et tout colorer reviendrait à ne rien signaler.
    /// Isolée sur l'acteur principal, comme les couleurs de la charte (`Brand`).
    @MainActor var tint: Color {
        switch self {
        case .information: Brand.textSecondary
        case .important: Brand.warning
        case .urgent: Brand.error
        }
    }
}

// MARK: - Activités

/// Ligne de `activites` réduite à sa forme d'origine : nom et horaire
/// hebdomadaire en texte. (Les colonnes ajoutées depuis, type, statut, dates,
/// places, sont lues par `Activity`.)
nonisolated struct ActivityRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `nom`.
    let nom: String?
    /// `jour` : jour de la semaine en toutes lettres.
    let jour: String?
    /// `heure` : heure en texte libre.
    let heure: String?
    /// `court_id` : terrain habituel.
    let courtId: UUID?
    /// `encadrant_nom` : nom affiché de l'encadrant.
    let encadrantNom: String?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, nom, jour, heure
        case courtId = "court_id"
        case encadrantNom = "encadrant_nom"
    }

    /// Colonnes demandées ; `created_at` sert au tri et n'est pas décodée.
    static let columns = "id, nom, jour, heure, court_id, encadrant_nom, created_at"

    /// Conversion vers le type du domaine.
    ///
    /// - Returns: `nil` pour une activité sans nom.
    func toDomain() -> ClubActivity? {
        guard let nom, !nom.isEmpty else { return nil }
        return ClubActivity(id: id, name: nom, day: jour, time: heure, courtId: courtId, coach: encadrantNom)
    }
}

/// Activité telle qu'affichée par la section de l'accueil.
nonisolated struct ClubActivity: Identifiable, Hashable, Sendable {
    /// `activites.id`.
    let id: UUID
    /// Nom de l'activité.
    let name: String
    /// Jour de la semaine en toutes lettres (« Mardi ») : la table décrit un
    /// horaire hebdomadaire, pas une date.
    let day: String?
    /// Heure en texte libre : saisie par l'admin (« 19 h 00 ») ou écrite par la
    /// fonction `creer_activite` pour un cours créé par un entraîneur (« 19h00 »).
    let time: String?
    /// Terrain habituel, dont le nom est retrouvé par l'appelant.
    let courtId: UUID?
    /// Nom de l'encadrant.
    let coach: String?

    /// « Mardi · 19 h 00 · Central » suivi du nom de l'encadrant, en omettant
    /// proprement les champs absents plutôt qu'en laissant des séparateurs
    /// orphelins.
    ///
    /// - Parameter courtName: nom du terrain, `nil` s'il est inconnu.
    /// - Returns: les éléments présents, séparés par « · ».
    func detailLine(courtName: String?) -> String {
        [day, time, courtName, coach]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
