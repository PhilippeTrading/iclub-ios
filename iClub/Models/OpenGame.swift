//
//  OpenGame.swift
//  iClub
//
//  Une partie ouverte **est** une réservation : une ligne de `reservations`
//  portant `est_partie_ouverte = true`. Il n'existe pas de table dédiée.
//
//  Elle hérite ainsi de la contrainte anti-double-réservation, de l'affichage
//  au planning, du temps réel, de « Mes réservations » et de l'annulation,
//  sans qu'aucun de ces mécanismes ait à connaître la notion de partie ouverte.
//
//  Rôle
//    Les énumérations des réglages d'une partie (mixité, ambiance, équipe,
//    côté), la ligne décodée `OpenGameRow` (une réservation avec son terrain
//    et ses joueurs) et le modèle de domaine `OpenGame` : places, temps,
//    libellés, rôle de l'utilisateur et textes de ses actions.
//
//  Place dans l'application
//    `OpenGameService.loadAll` lit les lignes et les convertit (`toDomain`).
//    `OpenGamesStore` garde les `OpenGame` et les sert à la liste
//    (`OpenGamesView`, `OpenGameCard`, `PlayerSlotView`, `PlayerProfileSheet`),
//    au formulaire de création (`OpenGameFormView`, qui propose aussi `Mixite`
//    et `Ambiance`) et au moteur d'admission (`OpenGameEligibility`).
//    `OpenGameService.join` et `OpenGameService.create` écrivent en base les
//    valeurs brutes de `Team`, `Side`, `Mixite` et `Ambiance`.
//
//  Colonnes et valeurs de la base
//    - `reservations` : `est_partie_ouverte`, `niveau_min`, `niveau_max`,
//      `mixite` (« mixte », « hommes », « femmes ») et `ambiance` (« loisir »,
//      « competitif ») viennent de la migration 20260923150000 ;
//      `sous_reserve_pluie`, de 20261030120000.
//    - `reservation_participants` : `equipe` (« A », « B ») et `cote`
//      (« gauche », « droite », « indifferent ») viennent de 20260924110000.
//    Les valeurs brutes des énumérations sont exactement celles qu'admettent
//    les contraintes `check` de ces colonnes.
//
//  Sous réserve de pluie
//    `reservations.sous_reserve_pluie` est posé par la base, à la création de
//    la réservation seulement (déclencheur `sous_reserve_pluie`, fonction
//    `marquer_sous_reserve_pluie`) : vrai quand la réservation est confirmée
//    et qu'un cours ou un stage se tient au même moment sur un terrain
//    extérieur du même sport (fonction `cours_exterieurs_concurrents`). Il
//    n'est jamais recalculé ensuite : changer l'horaire ou le terrain, ou
//    créer plus tard un cours extérieur au même moment, ne le met pas à jour
//    (limite consignée côté web). L'app le lit pour le badge de la carte et ne
//    l'écrit jamais.
//
//  Points d'attention
//    - Limite connue : la colonne `adultes_uniquement` (20261018160000) n'est
//      pas lue. L'app n'affiche donc pas le badge « Adultes uniquement » du
//      web, et un mineur n'apprend le refus qu'à la réponse de
//      `join_open_game` (« Cette partie est réservée aux adultes »).
//    - Limite connue : les participants sans profil (invités non membres,
//      comptes supprimés) ne sont pas repris dans `players` (voir `toDomain`).
//    - Les jours et les heures sont interprétés dans le fuseau de l'appareil,
//      pas dans celui du club (défaut consigné pour toute l'app).
//
//  Fil d'exécution
//    Types `nonisolated` et `Sendable` : les lignes sont décodées hors de
//    l'acteur principal et les parties circulent entre les tâches.
//

import Foundation

// MARK: - Énumérations

/// Mixité d'une partie (`reservations.mixite`) : qui a le droit de la
/// rejoindre. La règle est stricte : `join_open_game` l'impose en base
/// (migration 20260923160000) et `OpenGameEligibility` l'explique avant
/// l'envoi.
nonisolated enum Mixite: String, CaseIterable, Identifiable, Sendable {
    /// Ouverte à tous. C'est aussi la valeur retenue quand la colonne est vide
    /// ou inconnue (voir `OpenGameRow.toDomain`).
    case mixte
    /// Réservée aux joueurs dont `profiles.sexe` vaut « H ».
    case hommes
    /// Réservée aux joueuses dont `profiles.sexe` vaut « F ».
    case femmes

    /// Identifiant pour les listes SwiftUI : la valeur brute.
    var id: String { rawValue }

    /// Libellé du bouton de choix, dans le formulaire de création.
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

    /// Sexe requis, `nil` si la partie est ouverte à tous. Comparé au sexe du
    /// profil par `OpenGameEligibility`, comme `join_open_game` le fait en
    /// base.
    var requiredSexe: Sexe? {
        switch self {
        case .mixte: nil
        case .hommes: .homme
        case .femmes: .femme
        }
    }
}

/// Ambiance d'une partie (`reservations.ambiance`). Simple indication pour
/// les autres joueurs : aucune règle n'en dépend, ni dans l'app ni en base.
nonisolated enum Ambiance: String, CaseIterable, Identifiable, Sendable {
    /// Pour le plaisir. Valeur retenue aussi quand la colonne est vide ou
    /// inconnue.
    case loisir
    /// Match disputé.
    case competitif

    /// Identifiant pour les listes SwiftUI : la valeur brute.
    var id: String { rawValue }

    /// Libellé du bouton de choix, dans le formulaire de création.
    var displayName: String {
        switch self {
        case .loisir: "Loisir"
        case .competitif: "Compétitif"
        }
    }

    /// Précision affichée sous le libellé, dans le formulaire de création.
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

/// Équipe d'un joueur dans un double (`reservation_participants.equipe`).
/// Deux places par équipe ; la notion n'existe pas en simple.
nonisolated enum Team: String, CaseIterable, Identifiable, Sendable {
    /// Équipe A, celle de l'hôte, et celle que la base choisit quand aucune
    /// n'est demandée.
    case a = "A"
    /// Équipe B.
    case b = "B"

    /// Identifiant pour les listes SwiftUI : la valeur brute.
    var id: String { rawValue }
    /// « Équipe A », « Équipe B ».
    var displayName: String { "Équipe \(rawValue)" }
}

/// Position sur le terrain. **N'existe qu'au padel** : au tennis les joueurs
/// changent de côté en permanence, la question n'a pas de sens.
///
/// La colonne `reservation_participants.cote` existe pourtant pour tous les
/// sports : hors padel, l'app envoie toujours « indifferent ».
nonisolated enum Side: String, CaseIterable, Identifiable, Sendable {
    /// Côté gauche.
    case gauche
    /// Côté droit.
    case droite
    /// Sans préférence : la valeur que prend `join_open_game` quand aucun côté
    /// n'est demandé, et celle que l'app retient pour un côté absent ou
    /// inconnu.
    case indifferent

    /// Identifiant pour les listes SwiftUI : la valeur brute.
    var id: String { rawValue }

    /// Libellé du choix et de la vignette du joueur.
    var displayName: String {
        switch self {
        case .gauche: "Gauche"
        case .droite: "Droite"
        case .indifferent: "Indifférent"
        }
    }
}

// MARK: - DTO

/// Ligne de `reservations` lue pour les parties ouvertes, avec son terrain
/// (`courts`) et ses joueurs (`reservation_participants`), telle que la rend
/// PostgREST.
///
/// Presque tout est optionnel : une valeur absente ne doit pas faire échouer
/// le décodage. C'est `toDomain` qui écarte une ligne inexploitable.
nonisolated struct OpenGameRow: Decodable, Sendable {
    /// `reservations.id` : l'identifiant de la partie est celui de la
    /// réservation.
    let id: UUID
    /// `date` : jour de la partie, « AAAA-MM-JJ ».
    let date: String?
    /// `heure_debut` : « HH:MM:SS », heure locale du club.
    let heureDebut: String?
    /// `heure_fin` : même format. Non nulle en base.
    let heureFin: String?
    /// `statut` : « confirmee » ou « annulee ».
    let statut: String?
    /// `format` : « simple » ou « double ». Absent ou inconnu, la ligne est
    /// écartée.
    let format: String?
    /// `mixite` : « mixte », « hommes » ou « femmes » ; `nil` vaut mixte.
    let mixite: String?
    /// `ambiance` : « loisir » ou « competitif » ; `nil` vaut loisir.
    let ambiance: String?
    /// `niveau_min` : borne basse de la fourchette de niveau, dans l'échelle
    /// du sport (classement au tennis, niveau au padel) ; `nil` sans
    /// fourchette.
    let niveauMin: String?
    /// `niveau_max` : borne haute, même échelle ; `nil` sans fourchette.
    let niveauMax: String?
    /// `created_by` : profil du créateur, l'hôte de la partie.
    let createdBy: UUID?
    /// `court_id` : terrain de la partie.
    let courtId: UUID?
    /// `sous_reserve_pluie` (migration 20261030120000) : vrai quand la base a
    /// marqué la réservation à sa création, terrain couvert pris pendant un
    /// cours en extérieur du même sport. `nil` quand la colonne n'a pas été
    /// demandée (lecture de repli de `OpenGameService.loadAll`).
    let sousReservePluie: Bool?
    /// Terrain joint (`courts`), `nil` s'il n'a pas pu être lu.
    let court: CourtBrief?
    /// Joueurs joints (`reservation_participants`), dans l'ordre rendu par
    /// PostgREST : aucun tri n'est demandé. Non optionnel : la sélection le
    /// demande toujours, et une partie sans joueur rend un tableau vide.
    let participants: [ParticipantRow]

    /// Le terrain joint, réduit aux colonnes demandées.
    nonisolated struct CourtBrief: Decodable, Sendable {
        /// `courts.nom` : nom affiché du terrain.
        let nom: String?
        /// `courts.surface` : lue, mais pas reprise dans `OpenGame`.
        let surface: String?
        /// `courts.couvert` : lu, mais pas repris dans `OpenGame`.
        let couvert: Bool?
        /// `courts.sport` : « tennis », « padel » ou « pickleball ». Absent ou
        /// inconnu, la ligne est écartée.
        let sport: String?
        /// `courts.duree_creneau_minutes` : durée d'un créneau sur ce terrain,
        /// en minutes. Ne sert que si l'heure de fin est illisible.
        let dureeCreneauMinutes: Int?

        /// Correspondance avec les colonnes SQL.
        enum CodingKeys: String, CodingKey {
            case nom, surface, couvert, sport
            case dureeCreneauMinutes = "duree_creneau_minutes"
        }
    }

    /// Un joueur de la partie, tel que joint par PostgREST.
    nonisolated struct ParticipantRow: Decodable, Sendable {
        /// `profile_id` : profil du joueur ; `nil` pour un invité non membre
        /// ou un compte supprimé, et la ligne est alors écartée par `toDomain`.
        let profileId: UUID?
        /// `nom_affiche` : nom recopié à l'inscription.
        let nomAffiche: String?
        /// `equipe` : « A » ou « B » en double, `nil` en simple.
        let equipe: String?
        /// `cote` : « gauche », « droite » ou « indifferent » ; `nil` vaut
        /// indifférent.
        let cote: String?

        /// Correspondance avec les colonnes SQL.
        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case nomAffiche = "nom_affiche"
            case equipe, cote
        }
    }

    /// Correspondance avec les colonnes SQL. `courts` et
    /// `reservation_participants` sont les noms des ressources jointes par
    /// PostgREST.
    enum CodingKeys: String, CodingKey {
        case id, date, statut, format, mixite, ambiance
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case niveauMin = "niveau_min"
        case niveauMax = "niveau_max"
        case createdBy = "created_by"
        case courtId = "court_id"
        case sousReservePluie = "sous_reserve_pluie"
        case court = "courts"
        case participants = "reservation_participants"
    }

    /// Colonnes demandées à PostgREST, sans le marqueur de pluie.
    ///
    /// La chaîne s'écrit sur plusieurs lignes : chaque barre oblique inverse
    /// en fin de ligne supprime le retour à la ligne, et PostgREST reçoit une
    /// seule liste. Les jointures `courts(...)` et
    /// `reservation_participants(...)` suivent les clés étrangères `court_id`
    /// et `reservation_id`. `est_partie_ouverte` est demandée sans être
    /// décodée : la requête filtre déjà dessus.
    static let columns = """
        id, date, heure_debut, heure_fin, statut, format, mixite, ambiance, \
        niveau_min, niveau_max, created_by, est_partie_ouverte, court_id, \
        courts(nom, surface, couvert, sport, duree_creneau_minutes), \
        reservation_participants(profile_id, nom_affiche, equipe, cote)
        """

    /// Avec le marqueur de pluie (migration du 30 octobre 2026).
    ///
    /// C'est la lecture normale, la migration étant appliquée depuis ce jour :
    /// `columns` seule ne sert plus qu'au repli de `OpenGameService.loadAll`,
    /// pour une base où la colonne n'existerait pas.
    static let columnsWithRain = columns + ", sous_reserve_pluie"

    /// Convertit la ligne en partie du domaine.
    ///
    /// - Returns: la partie, ou `nil` si le jour, l'heure de début, le sport
    ///   du terrain ou le format manquent ou sont illisibles. Une telle ligne
    ///   disparaît de la liste sans erreur.
    func toDomain() -> OpenGame? {
        // Champs indispensables : sans eux, la partie ne peut être ni placée
        // dans la journée, ni rattachée à un sport, ni dimensionnée. Le jour
        // est lu à minuit dans le fuseau de l'appareil.
        guard let day = SupabaseDate.parse(date),
              let startMinutes = ClubSportSettingsRow.minutes(from: heureDebut),
              let sport = court?.sport.flatMap({ Sport(rawValue: $0.lowercased()) }),
              let format = format.flatMap({ GameFormat(rawValue: $0.lowercased()) })
        else { return nil }

        // Fin : celle de la base ; à défaut (heure illisible), le début plus
        // la durée du terrain, ou une heure si le terrain manque aussi.
        let endMinutes = ClubSportSettingsRow.minutes(from: heureFin)
            ?? (startMinutes + (court?.dureeCreneauMinutes ?? 60))

        return OpenGame(
            id: id,
            date: day,
            // Créneau en minutes depuis minuit, d'une durée jamais négative.
            slot: TimeSlot(
                startMinutes: startMinutes,
                durationMinutes: max(0, endMinutes - startMinutes)
            ),
            sport: sport,
            // Nom du terrain illisible : un nom générique plutôt qu'une partie
            // perdue.
            courtName: court?.nom ?? "Terrain",
            format: format,
            // Mixité et ambiance absentes ou inconnues : les valeurs courantes,
            // comme en base (une mixité nulle n'y restreint rien).
            mixite: mixite.flatMap { Mixite(rawValue: $0.lowercased()) } ?? .mixte,
            ambiance: ambiance.flatMap { Ambiance(rawValue: $0.lowercased()) } ?? .loisir,
            niveauMin: niveauMin,
            niveauMax: niveauMax,
            hostId: createdBy,
            // Toujours faux en pratique : `OpenGameService.loadAll` ne lit que
            // les parties confirmées.
            isCancelled: statut == ReservationInsert.cancelledStatus,
            courtId: courtId,
            // Pluie : colonne non demandée (lecture de repli) ou nulle, pas de
            // badge.
            isRainReserve: sousReservePluie ?? false,
            // Seuls les joueurs avec un profil sont repris.
            // Limite connue : un participant sans profil (invité non membre,
            // compte supprimé) n'apparaît pas sur la carte, et sa place compte
            // pour libre dans `freeSlots`, alors que `join_open_game` le compte
            // (« tous participants confondus ») : l'app peut proposer
            // « Rejoindre » et la base répondre « Cette partie est complète ».
            // Le cas se présente pour une réservation avec invité que le club
            // transforme en partie ouverte (`ouvrir_partie_depuis_reservation`,
            // migration 20261022100000).
            players: participants.compactMap { row in
                guard let profileId = row.profileId else { return nil }
                return OpenGame.Player(
                    profileId: profileId,
                    // Nom manquant : « Joueur ».
                    displayName: row.nomAffiche ?? "Joueur",
                    // Équipe lue en majuscules (« A », « B ») ; `nil` en simple.
                    team: row.equipe.flatMap { Team(rawValue: $0.uppercased()) },
                    // Côté absent ou inconnu : indifférent.
                    side: row.cote.flatMap { Side(rawValue: $0.lowercased()) } ?? .indifferent
                )
            }
        )
    }
}

// MARK: - Domaine

/// Une partie ouverte, prête à afficher et à rejoindre.
///
/// Valeur immuable, refaite à chaque lecture de la base
/// (`OpenGamesStore.reload`). Identifiée par `id`, celui de la réservation.
nonisolated struct OpenGame: Identifiable, Hashable, Sendable {

    /// Un joueur inscrit, membre du club avec un profil, hôte compris.
    nonisolated struct Player: Identifiable, Hashable, Sendable {
        /// `reservation_participants.profile_id`.
        let profileId: UUID
        /// `reservation_participants.nom_affiche`, ou « Joueur » à défaut.
        let displayName: String
        /// `nil` en simple, où la notion d'équipe n'existe pas.
        let team: Team?
        /// Côté souhaité ; « indifférent » hors padel.
        let side: Side

        /// Identifiant pour les listes : le profil. Un joueur ne figure qu'une
        /// fois dans une partie, `join_open_game` le vérifie.
        var id: UUID { profileId }

        /// Prénom seul : le nom complet se tronque et devient illisible dans
        /// une vignette de joueur. C'est le premier mot du nom affiché, ou le
        /// nom entier s'il ne contient pas d'espace.
        var firstName: String {
            displayName.split(separator: " ").first.map(String.init) ?? displayName
        }

        /// Initiales des deux premiers mots du nom, en majuscules (« MD » pour
        /// « Marie Dupont ») ; « ? » pour un nom vide. Repli des vignettes
        /// tant que la fiche du joueur (`RosterInfoRow`) n'est pas chargée.
        var initials: String {
            let parts = displayName.split(separator: " ").prefix(2)
            let value = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
            return value.isEmpty ? "?" : value
        }
    }

    /// `reservations.id` : la partie est la réservation.
    let id: UUID
    /// Jour de la partie, à minuit dans le fuseau de l'appareil.
    let date: Date
    /// Début et durée, en minutes depuis minuit.
    let slot: TimeSlot
    /// Sport du terrain.
    let sport: Sport
    /// Nom du terrain, « Terrain » s'il n'a pas pu être lu.
    let courtName: String
    /// Simple ou double : fixe la capacité.
    let format: GameFormat
    /// Qui peut rejoindre.
    let mixite: Mixite
    /// Loisir ou compétitif, indication affichée seulement.
    let ambiance: Ambiance
    /// Borne basse de niveau (`reservations.niveau_min`), `nil` sans
    /// fourchette.
    let niveauMin: String?
    /// Borne haute de niveau (`reservations.niveau_max`), `nil` sans
    /// fourchette.
    let niveauMax: String?
    /// Profil de l'hôte (`reservations.created_by`).
    let hostId: UUID?
    /// Partie annulée. Toujours faux pour les parties lues par
    /// `OpenGameService.loadAll`, qui ne garde que les confirmées.
    let isCancelled: Bool
    /// Terrain de la partie : sert à écarter celles qui se jouent sur un
    /// terrain fermé à la personne.
    ///
    /// `var` avec une valeur par défaut, comme `isRainReserve` : l'initialiseur
    /// par membre les rend facultatifs, et les aperçus Xcode de `OpenGameCard`
    /// les omettent.
    var courtId: UUID? = nil
    /// Terrain couvert repris par un cours extérieur s'il pleut
    /// (`reservations.sous_reserve_pluie`, posé par la base).
    ///
    /// `OpenGameCard` l'affiche : parapluie sur la carte repliée, badge
    /// « Sous réserve de pluie » et explication sur la carte dépliée. Faux
    /// quand la colonne n'a pas été lue (repli de `OpenGameService.loadAll`).
    var isRainReserve = false
    /// Joueurs inscrits avec un profil, hôte compris, dans l'ordre de la base.
    let players: [Player]

    // MARK: Places

    /// Nombre de joueurs attendus : 2 en simple, 4 en double.
    var capacity: Int { format.capacity }
    /// Places libres, jamais négatives. Voir la limite de `toDomain` sur les
    /// participants sans profil.
    var freeSlots: Int { max(0, capacity - players.count) }
    /// Plus aucune place libre.
    var isFull: Bool { freeSlots == 0 }

    /// Le côté ne se demande et ne s'affiche qu'au padel.
    var usesSides: Bool { sport == .padel }

    /// Les équipes n'existent qu'en double.
    var usesTeams: Bool { format == .double }

    /// Joueurs d'une équipe, dans l'ordre de `players`.
    ///
    /// - Parameter team: l'équipe voulue.
    /// - Returns: ses joueurs ; vide en simple, où personne n'a d'équipe.
    func players(in team: Team) -> [Player] {
        players.filter { $0.team == team }
    }

    /// Places restantes d'une équipe : deux joueurs par équipe en double. La
    /// base applique la même limite (« L'équipe A est complète »).
    ///
    /// - Parameter team: l'équipe voulue.
    /// - Returns: 0, 1 ou 2.
    func freeSlots(in team: Team) -> Int {
        max(0, 2 - players(in: team).count)
    }

    /// Première équipe ayant de la place, visée par le bouton « Rejoindre ».
    /// `nil` en simple, ou quand les deux équipes sont pleines.
    var firstTeamWithRoom: Team? {
        guard usesTeams else { return nil }
        return Team.allCases.first { freeSlots(in: $0) > 0 }
    }

    // MARK: Temps

    /// Début de la partie : le jour à minuit plus l'heure de début, dans le
    /// fuseau de l'appareil (la base, elle, compte dans le fuseau du club). Le
    /// jour à minuit si le calcul échoue.
    var startsAt: Date {
        let calendar = Calendar.current
        return calendar.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: calendar.startOfDay(for: date)
        ) ?? date
    }

    /// Vrai dès l'heure de début atteinte, à l'horloge de l'appareil.
    /// `join_open_game` refuse aussi une partie commencée (« Cette partie a
    /// déjà commencé »).
    var hasStarted: Bool { startsAt <= .now }

    /// Visible dans « Parties ouvertes » : ni complète, ni commencée, ni annulée.
    var isOpenForJoining: Bool {
        !isFull && !hasStarted && !isCancelled
    }

    /// La tâche planifiée annule la partie 30 minutes avant le début si l'hôte
    /// est encore seul. L'app ne déclenche rien, mais doit prévenir : c'est une
    /// dernière chance pour quelqu'un de s'inscrire.
    ///
    /// La tâche est `cancel_stale_open_games` (pg_cron, toutes les cinq
    /// minutes, migration 20260923170000) : elle annule les parties ouvertes
    /// confirmées qui comptent au plus un joueur et dont le début, dans le
    /// fuseau du club, est à 30 minutes ou moins, ou déjà passé (jusqu'à sept
    /// jours). En secondes.
    static let automaticCancellationLeadTime: TimeInterval = 30 * 60

    /// Vrai pour une partie non annulée, pas encore commencée, avec au plus un
    /// joueur, qui commence dans 30 minutes ou moins : la condition de la
    /// tâche planifiée. Celle-ci ne passant que toutes les cinq minutes, la
    /// partie peut être déjà annulée en base quand l'alerte s'affiche ; elle
    /// quitte alors la liste à la relecture suivante.
    var isFacingAutomaticCancellation: Bool {
        guard !isCancelled, !hasStarted, players.count <= 1 else { return false }
        return startsAt.timeIntervalSince(.now) <= Self.automaticCancellationLeadTime
    }

    /// Texte de l'alerte d'annulation imminente, sur la carte dépliée.
    ///
    /// - Parameter isHost: vrai quand c'est l'hôte qui regarde.
    /// - Returns: la phrase à afficher, tournée vers l'hôte ou vers les autres.
    func automaticCancellationWarning(isHost: Bool) -> String {
        isHost
            ? "Personne ne vous a rejoint : la partie sera annulée automatiquement et le créneau libéré"
            : "Sans joueur supplémentaire, cette partie sera annulée automatiquement"
    }

    // MARK: Libellés

    /// Fourchette de niveau (`Ranking.rangeLabel`, « Tous niveaux » sans
    /// fourchette), puis le format, séparés par un point médian.
    var levelAndFormatLabel: String {
        let level = Ranking.rangeLabel(min: niveauMin, max: niveauMax, sport: sport)
        return "\(level) · \(format.displayName)"
    }

    /// « Complet », « 1 place » ou « 3 places ».
    var freeSlotsLabel: String {
        guard !isFull else { return "Complet" }
        return freeSlots > 1 ? "\(freeSlots) places" : "1 place"
    }

    /// Vrai si ce profil a créé la partie.
    ///
    /// - Parameter profileId: profil à tester.
    func isHost(_ profileId: UUID) -> Bool { hostId == profileId }

    /// Vrai si ce profil figure parmi les joueurs.
    ///
    /// - Parameter profileId: profil à tester.
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

    /// Rôle d'un profil dans la partie.
    ///
    /// - Parameter profileId: profil regardé (soi, ou l'enfant pour qui l'on
    ///   agit) ; `nil` vaut extérieur.
    /// - Returns: `.host` pour le créateur, même s'il ne figure pas parmi les
    ///   joueurs ; `.player` pour un inscrit ; `.outsider` sinon.
    func role(for profileId: UUID?) -> Role {
        guard let profileId else { return .outsider }
        if isHost(profileId) { return .host }
        return contains(profileId) ? .player : .outsider
    }

    // MARK: Libellés de l'action

    /// Libellé du bouton d'action de la carte, selon le rôle.
    ///
    /// - Parameter role: rôle de l'utilisateur dans la partie.
    /// - Returns: « Annuler la partie », « Quitter la partie » ou « Rejoindre ».
    static func actionTitle(for role: Role) -> String {
        switch role {
        case .host: "Annuler la partie"
        case .player: "Quitter la partie"
        case .outsider: "Rejoindre"
        }
    }

    /// Symbole SF Symbols du même bouton.
    ///
    /// - Parameter role: rôle de l'utilisateur dans la partie.
    /// - Returns: le nom du symbole.
    static func actionSymbol(for role: Role) -> String {
        switch role {
        case .host: "xmark.circle"
        case .player: "person.badge.minus"
        case .outsider: "person.badge.plus"
        }
    }

    /// Titre de la fenêtre de confirmation quand un joueur quitte la partie.
    var leaveConfirmationTitle: String {
        "Quitter cette partie ?"
    }

    /// Titre de la fenêtre de confirmation quand l'hôte annule la partie.
    var cancelConfirmationTitle: String {
        "Annuler cette partie ?"
    }

    /// Message de confirmation pour l'hôte. Il dit explicitement combien de
    /// joueurs seront retirés : annuler une partie où d'autres se sont
    /// inscrits n'est pas le même geste qu'annuler une partie vide. Les autres
    /// joueurs sont comptés en retirant l'hôte du total.
    var hostCancellationMessage: String {
        let others = max(0, players.count - 1)
        let consequence = "Le créneau sera rendu au club."

        // Partie où l'hôte est seul : la conséquence suffit.
        guard others > 0 else { return consequence }
        let inscrits = others > 1
            ? "\(others) autres joueurs sont inscrits"
            : "1 autre joueur est inscrit"
        return "\(inscrits) : la partie sera annulée pour tout le monde. \(consequence)"
    }

    /// Message de confirmation pour un joueur qui part : la partie continue
    /// sans lui.
    ///
    /// Attention : tutoiement (« Ta place »), quand les autres messages de la
    /// partie vouvoient (« Personne ne vous a rejoint »).
    var playerLeaveMessage: String {
        "Ta place sera libérée et la partie restera ouverte aux autres membres."
    }
}
