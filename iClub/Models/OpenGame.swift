//
//  OpenGame.swift
//  iClub
//
//  Une partie ouverte **est** une réservation : une ligne de `reservations`
//  portant `est_partie_ouverte = true`. Il n'existe pas de table dédiée.
//
//  Elle hérite ainsi de la contrainte anti-double-réservation, de l'affichage
//  au planning, du temps réel, de « Mes réservations » et de l'annulation —
//  sans qu'aucun de ces mécanismes ait à connaître la notion de partie ouverte.
//

import Foundation

// MARK: - Énumérations

nonisolated enum Mixite: String, CaseIterable, Identifiable, Sendable {
    case mixte
    case hommes
    case femmes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mixte: "Mixte"
        case .hommes: "Hommes"
        case .femmes: "Femmes"
        }
    }

    /// Badge affiché sur la carte. Rien pour une partie mixte, qui est le cas courant.
    var badge: String? {
        switch self {
        case .mixte: nil
        case .hommes: "Hommes uniquement"
        case .femmes: "Femmes uniquement"
        }
    }

    /// Phrase expliquant l'effet du choix, sous les boutons de création.
    var effect: String {
        switch self {
        case .mixte: "Tout le monde peut rejoindre cette partie"
        case .hommes: "Seuls les hommes pourront rejoindre cette partie"
        case .femmes: "Seules les femmes pourront rejoindre cette partie"
        }
    }

    /// Sexe requis, `nil` si la partie est ouverte à tous.
    var requiredSexe: Sexe? {
        switch self {
        case .mixte: nil
        case .hommes: .homme
        case .femmes: .femme
        }
    }
}

nonisolated enum Ambiance: String, CaseIterable, Identifiable, Sendable {
    case loisir
    case competitif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .loisir: "Loisir"
        case .competitif: "Compétitif"
        }
    }

    var detail: String {
        switch self {
        case .loisir: "Pour jouer sans enjeu"
        case .competitif: "Match sérieux"
        }
    }

    /// Seul « compétitif » porte un badge : « loisir » est le cas courant.
    var badge: String? {
        self == .competitif ? "Compétitif" : nil
    }
}

nonisolated enum Team: String, CaseIterable, Identifiable, Sendable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
    var displayName: String { "Équipe \(rawValue)" }
}

/// Position sur le terrain. **N'existe qu'au padel** : au tennis les joueurs
/// changent de côté en permanence, la question n'a pas de sens.
nonisolated enum Side: String, CaseIterable, Identifiable, Sendable {
    case gauche
    case droite
    case indifferent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gauche: "Gauche"
        case .droite: "Droite"
        case .indifferent: "Indifférent"
        }
    }
}

// MARK: - DTO

nonisolated struct OpenGameRow: Decodable, Sendable {
    let id: UUID
    let date: String?
    let heureDebut: String?
    let heureFin: String?
    let statut: String?
    let format: String?
    let mixite: String?
    let ambiance: String?
    let niveauMin: String?
    let niveauMax: String?
    let createdBy: UUID?
    let court: CourtBrief?
    let participants: [ParticipantRow]

    nonisolated struct CourtBrief: Decodable, Sendable {
        let nom: String?
        let surface: String?
        let couvert: Bool?
        let sport: String?
        let dureeCreneauMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case nom, surface, couvert, sport
            case dureeCreneauMinutes = "duree_creneau_minutes"
        }
    }

    nonisolated struct ParticipantRow: Decodable, Sendable {
        let profileId: UUID?
        let nomAffiche: String?
        let equipe: String?
        let cote: String?

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case nomAffiche = "nom_affiche"
            case equipe, cote
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, date, statut, format, mixite, ambiance
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case niveauMin = "niveau_min"
        case niveauMax = "niveau_max"
        case createdBy = "created_by"
        case court = "courts"
        case participants = "reservation_participants"
    }

    static let columns = """
        id, date, heure_debut, heure_fin, statut, format, mixite, ambiance, \
        niveau_min, niveau_max, created_by, est_partie_ouverte, \
        courts(nom, surface, couvert, sport, duree_creneau_minutes), \
        reservation_participants(profile_id, nom_affiche, equipe, cote)
        """

    func toDomain() -> OpenGame? {
        guard let day = SupabaseDate.parse(date),
              let startMinutes = ClubSportSettingsRow.minutes(from: heureDebut),
              let sport = court?.sport.flatMap({ Sport(rawValue: $0.lowercased()) }),
              let format = format.flatMap({ GameFormat(rawValue: $0.lowercased()) })
        else { return nil }

        let endMinutes = ClubSportSettingsRow.minutes(from: heureFin)
            ?? (startMinutes + (court?.dureeCreneauMinutes ?? 60))

        return OpenGame(
            id: id,
            date: day,
            slot: TimeSlot(
                startMinutes: startMinutes,
                durationMinutes: max(0, endMinutes - startMinutes)
            ),
            sport: sport,
            courtName: court?.nom ?? "Terrain",
            format: format,
            mixite: mixite.flatMap { Mixite(rawValue: $0.lowercased()) } ?? .mixte,
            ambiance: ambiance.flatMap { Ambiance(rawValue: $0.lowercased()) } ?? .loisir,
            niveauMin: niveauMin,
            niveauMax: niveauMax,
            hostId: createdBy,
            isCancelled: statut == ReservationInsert.cancelledStatus,
            players: participants.compactMap { row in
                guard let profileId = row.profileId else { return nil }
                return OpenGame.Player(
                    profileId: profileId,
                    displayName: row.nomAffiche ?? "Joueur",
                    team: row.equipe.flatMap { Team(rawValue: $0.uppercased()) },
                    side: row.cote.flatMap { Side(rawValue: $0.lowercased()) } ?? .indifferent
                )
            }
        )
    }
}

// MARK: - Domaine

nonisolated struct OpenGame: Identifiable, Hashable, Sendable {

    nonisolated struct Player: Identifiable, Hashable, Sendable {
        let profileId: UUID
        let displayName: String
        /// `nil` en simple, où la notion d'équipe n'existe pas.
        let team: Team?
        let side: Side

        var id: UUID { profileId }

        /// Prénom seul : le nom complet se tronque et devient illisible dans
        /// une vignette de joueur.
        var firstName: String {
            displayName.split(separator: " ").first.map(String.init) ?? displayName
        }

        var initials: String {
            let parts = displayName.split(separator: " ").prefix(2)
            let value = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
            return value.isEmpty ? "?" : value
        }
    }

    let id: UUID
    let date: Date
    let slot: TimeSlot
    let sport: Sport
    let courtName: String
    let format: GameFormat
    let mixite: Mixite
    let ambiance: Ambiance
    let niveauMin: String?
    let niveauMax: String?
    let hostId: UUID?
    let isCancelled: Bool
    let players: [Player]

    // MARK: Places

    var capacity: Int { format.capacity }
    var freeSlots: Int { max(0, capacity - players.count) }
    var isFull: Bool { freeSlots == 0 }

    /// Le côté ne se demande et ne s'affiche qu'au padel.
    var usesSides: Bool { sport == .padel }

    /// Les équipes n'existent qu'en double.
    var usesTeams: Bool { format == .double }

    func players(in team: Team) -> [Player] {
        players.filter { $0.team == team }
    }

    /// Places restantes d'une équipe : deux joueurs par équipe en double.
    func freeSlots(in team: Team) -> Int {
        max(0, 2 - players(in: team).count)
    }

    /// Première équipe ayant de la place, visée par le bouton « Rejoindre ».
    var firstTeamWithRoom: Team? {
        guard usesTeams else { return nil }
        return Team.allCases.first { freeSlots(in: $0) > 0 }
    }

    // MARK: Temps

    var startsAt: Date {
        let calendar = Calendar.current
        return calendar.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: calendar.startOfDay(for: date)
        ) ?? date
    }

    var hasStarted: Bool { startsAt <= .now }

    /// Visible dans « Parties ouvertes » : ni complète, ni commencée, ni annulée.
    var isOpenForJoining: Bool {
        !isFull && !hasStarted && !isCancelled
    }

    /// La tâche planifiée annule la partie 30 minutes avant le début si l'hôte
    /// est encore seul. L'app ne déclenche rien, mais doit prévenir — c'est une
    /// dernière chance pour quelqu'un de s'inscrire.
    static let automaticCancellationLeadTime: TimeInterval = 30 * 60

    var isFacingAutomaticCancellation: Bool {
        guard !isCancelled, !hasStarted, players.count <= 1 else { return false }
        return startsAt.timeIntervalSince(.now) <= Self.automaticCancellationLeadTime
    }

    func automaticCancellationWarning(isHost: Bool) -> String {
        isHost
            ? "Personne ne vous a rejoint : la partie sera annulée automatiquement et le créneau libéré"
            : "Sans joueur supplémentaire, cette partie sera annulée automatiquement"
    }

    // MARK: Libellés

    var levelAndFormatLabel: String {
        let level = Ranking.rangeLabel(min: niveauMin, max: niveauMax, sport: sport)
        return "\(level) · \(format.displayName)"
    }

    var freeSlotsLabel: String {
        guard !isFull else { return "Complet" }
        return freeSlots > 1 ? "\(freeSlots) places" : "1 place"
    }

    func isHost(_ profileId: UUID) -> Bool { hostId == profileId }

    func contains(_ profileId: UUID) -> Bool {
        players.contains { $0.profileId == profileId }
    }

    // MARK: Rôle et action

    /// Place de l'utilisateur dans la partie. Elle détermine à elle seule
    /// l'action proposée sur la carte : rejoindre, quitter, ou annuler.
    nonisolated enum Role: Sendable {
        /// Créateur de la partie : la quitter l'annule pour tout le monde.
        case host
        /// Joueur inscrit, non créateur : ne libère que sa place.
        case player
        /// Pas encore dans la partie.
        case outsider
    }

    func role(for profileId: UUID?) -> Role {
        guard let profileId else { return .outsider }
        if isHost(profileId) { return .host }
        return contains(profileId) ? .player : .outsider
    }

    // MARK: Libellés de l'action

    static func actionTitle(for role: Role) -> String {
        switch role {
        case .host: "Annuler la partie"
        case .player: "Quitter la partie"
        case .outsider: "Rejoindre"
        }
    }

    static func actionSymbol(for role: Role) -> String {
        switch role {
        case .host: "xmark.circle"
        case .player: "person.badge.minus"
        case .outsider: "person.badge.plus"
        }
    }

    var leaveConfirmationTitle: String {
        "Quitter cette partie ?"
    }

    var cancelConfirmationTitle: String {
        "Annuler cette partie ?"
    }

    /// Message de confirmation pour l'hôte. Il dit explicitement combien de
    /// joueurs seront retirés : annuler une partie où d'autres se sont
    /// inscrits n'est pas le même geste qu'annuler une partie vide.
    var hostCancellationMessage: String {
        let others = max(0, players.count - 1)
        let consequence = "Le créneau sera rendu au club."

        guard others > 0 else { return consequence }
        let inscrits = others > 1
            ? "\(others) autres joueurs sont inscrits"
            : "1 autre joueur est inscrit"
        return "\(inscrits) : la partie sera annulée pour tout le monde. \(consequence)"
    }

    var playerLeaveMessage: String {
        "Ta place sera libérée et la partie restera ouverte aux autres membres."
    }
}
