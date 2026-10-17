//
//  ClubContent.swift
//  iClub
//
//  Annonces et activités du club, telles que l'admin les publie depuis le
//  back-office web.
//

import Foundation
import SwiftUI

// MARK: - Annonces

nonisolated enum AnnouncementLevel: String, Sendable {
    case information
    case important
    case urgent

    var displayName: String {
        switch self {
        case .information: "Information"
        case .important: "Important"
        case .urgent: "Urgent"
        }
    }
}

nonisolated struct AnnouncementRow: Decodable, Sendable {
    let id: UUID
    let niveau: String?
    let titre: String?
    let corps: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, niveau, titre, corps
        case createdAt = "created_at"
    }

    static let columns = "id, niveau, titre, corps, actif, created_at"

    func toDomain() -> Announcement? {
        guard let titre, !titre.isEmpty else { return nil }
        return Announcement(
            id: id,
            level: niveau.flatMap { AnnouncementLevel(rawValue: $0.lowercased()) } ?? .information,
            title: titre,
            body: corps ?? ""
        )
    }
}

nonisolated struct Announcement: Identifiable, Hashable, Sendable {
    let id: UUID
    let level: AnnouncementLevel
    let title: String
    let body: String
}

extension AnnouncementLevel {
    /// Teinte du badge. « Information » reste neutre : c'est le cas courant,
    /// et tout colorer reviendrait à ne rien signaler.
    @MainActor var tint: Color {
        switch self {
        case .information: Brand.textSecondary
        case .important: Brand.warning
        case .urgent: Brand.error
        }
    }
}

// MARK: - Activités

nonisolated struct ActivityRow: Decodable, Sendable {
    let id: UUID
    let nom: String?
    let jour: String?
    let heure: String?
    let courtId: UUID?
    let encadrantNom: String?

    enum CodingKeys: String, CodingKey {
        case id, nom, jour, heure
        case courtId = "court_id"
        case encadrantNom = "encadrant_nom"
    }

    static let columns = "id, nom, jour, heure, court_id, encadrant_nom, created_at"

    func toDomain() -> ClubActivity? {
        guard let nom, !nom.isEmpty else { return nil }
        return ClubActivity(id: id, name: nom, day: jour, time: heure, courtId: courtId, coach: encadrantNom)
    }
}

nonisolated struct ClubActivity: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// Jour de la semaine en toutes lettres (« Mardi ») : la table décrit un
    /// horaire hebdomadaire, pas une date.
    let day: String?
    /// Heure déjà mise en forme par l'admin (« 19 h 00 »).
    let time: String?
    let courtId: UUID?
    let coach: String?

    /// « Mardi · 19 h 00 · Central · Inès Lefèvre », en omettant proprement les
    /// champs absents plutôt qu'en laissant des séparateurs orphelins.
    func detailLine(courtName: String?) -> String {
        [day, time, courtName, coach]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
