//
//  Court.swift
//  iClub
//
//  Les terrains vivent en base et sont administrés depuis le back-office web :
//  rien n'est codé en dur ici, ni la liste, ni les tarifs, ni les durées de
//  créneau, ni l'ordre d'affichage.
//
//  Rôle
//    Type du domaine `Court` (un terrain réservable), sa ligne décodée
//    `CourtRow` (table `courts`) et le décodage tolérant des nombres
//    PostgreSQL (`PostgresNumber`).
//
//  Place dans l'application
//    `PlanningService.loadCourts` lit `courts` avec `CourtRow.columns` ;
//    `ClubCatalog` garde les `Court` obtenus et les sert au planning, aux
//    parties ouvertes et à la création de cours.
//
//  Droits et sécurité
//    `courts` est lisible par tous (RLS `courts_select_public`) ; seule
//    l'administration du club y écrit (`courts_write_admin`).
//

import Foundation

// MARK: - Domaine

/// Terrain actif d'un sport connu de l'app, prêt à afficher et à réserver.
struct Court: Identifiable, Hashable, Sendable {
    /// `courts.id`.
    let id: UUID
    /// `courts.club_id` : club propriétaire du terrain.
    let clubId: UUID
    /// `courts.nom` : nom affiché (« Central », « Padel 1 »…).
    let nom: String
    /// `courts.sport`, converti en `Sport`.
    let sport: Sport
    /// `courts.surface` : texte libre saisi par l'admin (« Terre battue »…),
    /// `nil` si non renseigné. Alimente le filtre de surface.
    let surface: String?
    /// `courts.eclaire` : terrain éclairé.
    let eclaire: Bool
    /// `courts.couvert` : terrain couvert (affiché « Intérieur »).
    let couvert: Bool
    /// Prix total du créneau, à partager entre `tarifCapacite` joueurs.
    /// Optionnel : un tarif absent ne doit pas faire disparaître le terrain.
    /// `courts.tarif_prix_total`, en euros.
    let tarifPrixTotal: Double?
    /// `courts.tarif_capacite` : nombre de joueurs entre lesquels le prix du
    /// créneau se partage.
    let tarifCapacite: Int?
    /// `courts.duree_creneau_minutes` : durée d'un créneau sur ce terrain, en
    /// minutes. Pas de la grille du planning.
    let dureeCreneauMinutes: Int
    /// `courts.ordre` : rang d'affichage à l'intérieur du sport, choisi par
    /// l'admin. `Int.max` quand la colonne est vide : le terrain passe en fin
    /// de liste.
    let ordre: Int

    /// « Terre battue · Extérieur · Éclairé » : mêmes règles que le web.
    var descriptionLabel: String {
        var parts: [String] = []
        if let surface, !surface.isEmpty { parts.append(surface) }
        parts.append(couvert ? "Intérieur" : "Extérieur")
        if eclaire { parts.append("Éclairé") }
        return parts.joined(separator: " · ")
    }

    /// Prix par joueur payant, `nil` si le club n'a pas renseigné de tarif.
    /// En euros, sans arrondi (l'arrondi se fait à l'affichage).
    var pricePerPlayer: Double? {
        // Capacité nulle : division impossible, tarif considéré absent.
        guard let tarifPrixTotal, let tarifCapacite, tarifCapacite > 0 else { return nil }
        return tarifPrixTotal / Double(tarifCapacite)
    }
}

// MARK: - DTO

/// Ligne de la table `courts` telle que la renvoie PostgREST.
///
/// `sport` est décodé en `String` : un sport inconnu de l'app ne doit pas faire
/// échouer le décodage de toute la liste, il est simplement ignoré plus haut.
nonisolated struct CourtRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `club_id`.
    let clubId: UUID
    /// `nom`.
    let nom: String
    /// `sport`, valeur brute.
    let sport: String
    /// `surface`, facultative.
    let surface: String?
    /// `eclaire` ; non nul en base, optionnel ici par prudence.
    let eclaire: Bool?
    /// `couvert` ; non nul en base, optionnel ici par prudence.
    let couvert: Bool?
    /// `tarif_prix_total` (`numeric(6, 2)`, euros).
    let tarifPrixTotal: Double?
    /// `tarif_capacite`.
    let tarifCapacite: Int?
    /// `duree_creneau_minutes` : seule colonne numérique obligatoire au décodage.
    let dureeCreneauMinutes: Int
    /// `actif` : un terrain désactivé par l'admin n'est pas proposé.
    let actif: Bool?
    /// `ordre`.
    let ordre: Int?

    /// Correspondance avec les colonnes SQL (pas de conversion automatique du
    /// snake_case).
    enum CodingKeys: String, CodingKey {
        case id, nom, sport, surface, eclaire, couvert, actif, ordre
        case clubId = "club_id"
        case tarifPrixTotal = "tarif_prix_total"
        case tarifCapacite = "tarif_capacite"
        case dureeCreneauMinutes = "duree_creneau_minutes"
    }

    /// Colonnes demandées à PostgREST.
    ///
    /// `note` est volontairement absente de la sélection : la colonne a été
    /// supprimée par la migration `20260923100000_drop_court_note.sql`.
    static let columns =
        "id, club_id, nom, sport, surface, eclaire, couvert, tarif_prix_total, tarif_capacite, duree_creneau_minutes, actif, ordre"

    /// Décodage écrit à la main pour tolérer les nombres renvoyés en chaîne.
    ///
    /// - Throws: `DecodingError` si un identifiant, le nom, le sport ou la
    ///   durée de créneau manquent ou sont illisibles. Dans une liste décodée
    ///   avec `Lenient`, la ligne est alors seulement écartée.
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

        // Sans durée de créneau, la grille ne peut pas être construite : la
        // ligne est refusée.
        guard let duree = PostgresNumber.int(container, .dureeCreneauMinutes) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dureeCreneauMinutes,
                in: container,
                debugDescription: "duree_creneau_minutes manquante ou illisible"
            )
        }
        dureeCreneauMinutes = duree
    }

    /// Conversion vers le type du domaine.
    ///
    /// - Returns: `nil` si le terrain est inactif ou porte un sport que l'app
    ///   ne connaît pas. `actif` absent vaut actif ; `eclaire` et `couvert`
    ///   absents valent faux.
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

/// Lecture d'un nombre qui peut arriver en entier, en décimal ou en chaîne
/// (cas des colonnes `numeric` de PostgreSQL selon la configuration de
/// PostgREST).
enum PostgresNumber {
    /// - Parameters:
    ///   - container: conteneur de décodage de la ligne.
    ///   - key: colonne à lire.
    /// - Returns: la valeur en `Double`, ou `nil` si absente ou illisible.
    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    /// - Parameters:
    ///   - container: conteneur de décodage de la ligne.
    ///   - key: colonne à lire.
    /// - Returns: la valeur en `Int` (un décimal est tronqué), ou `nil` si
    ///   absente ou illisible.
    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
