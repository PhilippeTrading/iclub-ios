//
//  Court.swift
//  iClub
//
//  Les terrains vivent en base et sont administrés depuis le back-office web :
//  rien n'est codé en dur ici — ni la liste, ni les tarifs, ni les durées de
//  créneau, ni l'ordre d'affichage.
//

import Foundation

// MARK: - Domaine

struct Court: Identifiable, Hashable, Sendable {
    let id: UUID
    let clubId: UUID
    let nom: String
    let sport: Sport
    let surface: String?
    let eclaire: Bool
    let couvert: Bool
    /// Prix total du créneau, à partager entre `tarifCapacite` joueurs.
    /// Optionnel : un tarif absent ne doit pas faire disparaître le terrain.
    let tarifPrixTotal: Double?
    let tarifCapacite: Int?
    let dureeCreneauMinutes: Int
    let ordre: Int

    /// « Terre battue · Extérieur · Éclairé » — mêmes règles que le web.
    var descriptionLabel: String {
        var parts: [String] = []
        if let surface, !surface.isEmpty { parts.append(surface) }
        parts.append(couvert ? "Intérieur" : "Extérieur")
        if eclaire { parts.append("Éclairé") }
        return parts.joined(separator: " · ")
    }

    /// Prix par joueur payant, `nil` si le club n'a pas renseigné de tarif.
    var pricePerPlayer: Double? {
        guard let tarifPrixTotal, let tarifCapacite, tarifCapacite > 0 else { return nil }
        return tarifPrixTotal / Double(tarifCapacite)
    }
}

// MARK: - DTO

/// `sport` est décodé en `String` : un sport inconnu de l'app ne doit pas faire
/// échouer le décodage de toute la liste, il est simplement ignoré plus haut.
nonisolated struct CourtRow: Decodable, Sendable {
    let id: UUID
    let clubId: UUID
    let nom: String
    let sport: String
    let surface: String?
    let eclaire: Bool?
    let couvert: Bool?
    let tarifPrixTotal: Double?
    let tarifCapacite: Int?
    let dureeCreneauMinutes: Int
    let actif: Bool?
    let ordre: Int?

    enum CodingKeys: String, CodingKey {
        case id, nom, sport, surface, eclaire, couvert, actif, ordre
        case clubId = "club_id"
        case tarifPrixTotal = "tarif_prix_total"
        case tarifCapacite = "tarif_capacite"
        case dureeCreneauMinutes = "duree_creneau_minutes"
    }

    // `note` est volontairement absente de la sélection : la colonne est en
    // cours de suppression côté base.
    static let columns =
        "id, club_id, nom, sport, surface, eclaire, couvert, tarif_prix_total, tarif_capacite, duree_creneau_minutes, actif, ordre"

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        clubId = try container.decode(UUID.self, forKey: .clubId)
        nom = try container.decode(String.self, forKey: .nom)
        sport = try container.decode(String.self, forKey: .sport)
        surface = try container.decodeIfPresent(String.self, forKey: .surface)
        eclaire = try container.decodeIfPresent(Bool.self, forKey: .eclaire)
        couvert = try container.decodeIfPresent(Bool.self, forKey: .couvert)
        actif = try container.decodeIfPresent(Bool.self, forKey: .actif)
        ordre = try container.decodeIfPresent(Int.self, forKey: .ordre)

        // `numeric` peut arriver en nombre ou en chaîne selon la configuration
        // de PostgREST : on accepte les deux plutôt que d'échouer sur un tarif.
        tarifPrixTotal = PostgresNumber.double(container, .tarifPrixTotal)
        tarifCapacite = PostgresNumber.int(container, .tarifCapacite)

        guard let duree = PostgresNumber.int(container, .dureeCreneauMinutes) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dureeCreneauMinutes,
                in: container,
                debugDescription: "duree_creneau_minutes manquante ou illisible"
            )
        }
        dureeCreneauMinutes = duree
    }

    /// `nil` si le terrain est inactif ou porte un sport que l'app ne connaît pas.
    func toDomain() -> Court? {
        guard actif ?? true else { return nil }
        guard let sport = Sport(rawValue: sport.lowercased()) else { return nil }

        return Court(
            id: id,
            clubId: clubId,
            nom: nom,
            sport: sport,
            surface: surface,
            eclaire: eclaire ?? false,
            couvert: couvert ?? false,
            tarifPrixTotal: tarifPrixTotal,
            tarifCapacite: tarifCapacite,
            dureeCreneauMinutes: dureeCreneauMinutes,
            ordre: ordre ?? Int.max
        )
    }
}

// MARK: - Décodage numérique tolérant

enum PostgresNumber {
    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
