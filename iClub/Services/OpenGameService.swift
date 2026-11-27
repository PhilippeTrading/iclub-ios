//
//  OpenGameService.swift
//  iClub
//
//  Lecture, adhésion, sortie et création des parties ouvertes.
//
//  Les deux fonctions `join_open_game` et `leave_open_game` portent toute la
//  logique métier côté base, sous verrou de ligne : deux personnes qui tapent
//  la dernière place au même instant ne peuvent pas entrer toutes les deux.
//  Elles lèvent des erreurs déjà rédigées en français (`P0001`), qui sont
//  affichées telles quelles : les vérifications côté app ne servent qu'à
//  éviter l'aller-retour, pas à remplacer celles de la base.
//
//  Place dans l'application
//    - `loadAll` : `OpenGamesStore.reload`, pour la liste de l'onglet
//      « Parties » et la règle d'une partie par jour.
//    - `join` : `OpenGamesView`, bouton « Rejoindre », pour soi ou pour un
//      enfant.
//    - `leave` : `OpenGamesView`, l'accueil (`HomeView`) et « Mes
//      réservations » (`ReservationsView`).
//    - `create` : `OpenGameFormView`, bouton « Ouvrir la partie ».
//
//  Tables, fonctions et garanties de la base
//    - `reservations` : lecture par tout membre du club (RLS
//      `reservations_select_club`) ; insertion dans un de ses clubs et à son
//      propre nom (`reservations_insert`, `created_by = auth.uid()`) ;
//      suppression réservée à l'administration du club
//      (`reservations_delete_admin`). Déclencheurs à l'insertion :
//      `acces_terrain` (terrain fermé à un groupe de l'hôte, refus P0001) et
//      `sous_reserve_pluie` (marqueur de pluie, calculé par la base quoi que
//      l'app envoie). Index unique `reservations_no_double_booking` (même
//      terrain, même jour, même heure de début, parmi les réservations
//      confirmées) : erreur `23505`.
//    - `reservation_participants` : lecture par tout membre du club, écriture
//      par le créateur de la réservation ou l'administration. Déclencheurs à
//      l'insertion : `one_open_game_per_day` (une seule partie ouverte par
//      jour et par joueur dans le club, refus P0001), `acces_terrain_partie`
//      (joueur qui rejoint, ou enfant inscrit, membre d'un groupe fermé à ce
//      terrain, refus P0001 ; le créateur qui s'inscrit n'est pas contrôlé)
//      et `trg_notifications_rejointes` (journal des notifications de
//      parties).
//    - `join_open_game(target_reservation_id, target_equipe, target_cote,
//      target_profile_id)`, version de la migration 20261018160000 :
//      contrôle le droit d'agir pour un enfant (`peut_agir_pour`), verrouille
//      la partie, puis contrôle la partie (ouverte, confirmée, d'un club de
//      l'appelant, pas commencée dans le fuseau du club), un joueur pas déjà
//      inscrit, « adultes uniquement », la mixité, la fourchette de niveau, la
//      capacité (tous participants confondus) et la place dans l'équipe, avant
//      d'inscrire le joueur.
//    - `leave_open_game(target_reservation_id)`, migration 20260923150000 :
//      l'hôte annule toute la réservation (les autres joueurs restent
//      inscrits sur une réservation annulée) ; un autre joueur ne retire que
//      sa propre ligne.
//
//  Droits et sécurité
//    Le client Supabase porte la session du membre (clé publique, jamais de
//    clé de service) : la RLS et les fonctions décident de tout. Les deux
//    fonctions sont `security definer` et refusent un appel sans session
//    (« Authentification requise »).
//
//  Effets de bord
//    Les écritures décrites ci-dessus ; `leave` retire en plus le rappel
//    local de la partie (`BookingReminders`).
//    Limite connue : les actions du web (`src/lib/actions/openGames.ts`)
//    envoient les courriels « partie créée », « partie rejointe » et « partie
//    complète ». L'app écrit directement en base : aucun courriel ne part
//    pour une partie créée ou rejointe depuis l'iPhone.
//
//  Points d'attention
//    - Attention : `create` écrit la réservation puis l'hôte en deux appels.
//      Si l'hôte est refusé (par exemple par `one_open_game_per_day`), le
//      rattrapage tente de supprimer la réservation, mais la RLS réserve la
//      suppression à l'administration : pour un adhérent, rien n'est
//      supprimé, sans erreur. La partie reste confirmée, sans joueur, visible
//      dans la liste, jusqu'à son annulation par la tâche
//      `cancel_stale_open_games` dans les 30 minutes qui précèdent son début
//      (défaut consigné pour le web et l'iOS). Le message de la base est en
//      outre remplacé par celui de `hostRegistrationFailed`.
//    - `leave_open_game` agit toujours pour le compte connecté : il ne retire
//      pas un enfant d'une partie (défaut consigné pour l'accueil).
//    - Limite connue : `loadAll` n'est pas paginée, et PostgREST ne rend pas
//      plus de mille lignes par appel.
//
//  Fil d'exécution
//    Fonctions statiques asynchrones, sur l'acteur principal (isolement par
//    défaut du projet) ; les charges utiles et les lignes sont `nonisolated`.
//

import Foundation
import Supabase

/// Erreurs des parties ouvertes, avec leur message affichable.
enum OpenGameError: LocalizedError {
    /// Refus métier venant de la base, déjà rédigé.
    case rejected(String)
    /// Le créneau visé a déjà commencé, à l'horloge de l'appareil ; rien n'a
    /// été envoyé.
    case slotInThePast
    /// Contrainte d'unicité : quelqu'un vient de réserver ce créneau.
    case slotAlreadyTaken
    /// L'hôte n'a pas pu être enregistré ; la suppression de la partie a été
    /// tentée (voir l'en-tête : pour un adhérent, elle n'aboutit pas).
    case hostRegistrationFailed

    /// Message montré à l'utilisateur, tel quel.
    ///
    /// Attention : celui de `slotAlreadyTaken` contient un tiret cadratin, et
    /// celui de `hostRegistrationFailed` tutoie (« Réessaie ») ; ce sont des
    /// textes affichés, à reprendre par un changement de code.
    var errorDescription: String? {
        switch self {
        case .rejected(let message):
            message
        case .slotInThePast:
            "Ce créneau est déjà passé."
        case .slotAlreadyTaken:
            "Ce créneau vient d'être réservé par quelqu'un d'autre — choisissez-en un autre."
        case .hostRegistrationFailed:
            "La partie n'a pas pu être ouverte. Réessaie."
        }
    }
}

// MARK: - Charges utiles

/// Insertion d'une partie ouverte. Séparée de `ReservationInsert` pour ne pas
/// envoyer de colonnes de partie ouverte sur une réservation classique.
///
/// Ni `sous_reserve_pluie` ni `on_behalf_of_club_member_id` ne sont envoyés :
/// la base calcule le premier, et une partie s'ouvre toujours au nom du
/// compte connecté. `mode_paiement` est absent aussi : rien n'est dû. Une
/// propriété optionnelle à `nil` n'est pas envoyée, et la colonne garde
/// `null`.
nonisolated struct OpenGameInsert: Encodable, Sendable {
    /// `club_id` : club du membre.
    let clubId: UUID
    /// `court_id` : terrain choisi.
    let courtId: UUID
    /// `date` : « AAAA-MM-JJ », jour calculé dans le fuseau de l'appareil.
    let date: String
    /// `heure_debut` : « HH:MM:00 ».
    let heureDebut: String
    /// `heure_fin` : « HH:MM:00 », début plus la durée du créneau.
    let heureFin: String
    /// `format` : « simple » ou « double ».
    let format: String
    /// `statut` : toujours « confirmee ».
    let statut: String
    /// `statut_paiement` : toujours « inclus », comme le web : une partie
    /// ouverte n'est pas facturée à sa création.
    let statutPaiement: String
    /// `montant_total` : toujours 0, en euros.
    let montantTotal: Double
    /// `created_by` : l'hôte. La RLS exige que ce soit le compte connecté.
    let createdBy: UUID
    /// `est_partie_ouverte` : toujours vrai.
    let estPartieOuverte: Bool
    /// `niveau_min` : borne basse, `nil` pour « tous niveaux » ou un sport sans
    /// échelle de niveau.
    let niveauMin: String?
    /// `niveau_max` : borne haute, même règle.
    let niveauMax: String?
    /// `mixite` : valeur brute de `Mixite`.
    let mixite: String
    /// `ambiance` : valeur brute de `Ambiance`.
    let ambiance: String

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case date, format, statut, mixite, ambiance
        case clubId = "club_id"
        case courtId = "court_id"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case statutPaiement = "statut_paiement"
        case montantTotal = "montant_total"
        case createdBy = "created_by"
        case estPartieOuverte = "est_partie_ouverte"
        case niveauMin = "niveau_min"
        case niveauMax = "niveau_max"
    }
}

/// L'hôte, inscrit comme participant. Porte `equipe` et `cote`, propres aux
/// parties ouvertes.
nonisolated struct OpenGameParticipantInsert: Encodable, Sendable {
    /// `reservation_id` : la partie qui vient d'être créée.
    let reservationId: UUID
    /// `profile_id` : l'hôte.
    let profileId: UUID
    /// `type` : « membre » (et non « invite »).
    let type: String
    /// `nom_affiche` : nom de l'hôte, recopié pour le planning et les cartes.
    let nomAffiche: String
    /// `supplement` : part à payer, toujours 0 (euros).
    let supplement: Double
    /// `used_credit` : aucun crédit invité, toujours faux.
    let usedCredit: Bool
    /// `equipe` : « A » en double ; `nil` en simple, et la clé n'est alors pas
    /// envoyée.
    let equipe: String?
    /// `cote` : toujours « indifferent » pour l'hôte.
    let cote: String

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case type, supplement, equipe, cote
        case reservationId = "reservation_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case usedCredit = "used_credit"
    }
}

/// Paramètres de `join_open_game`, nommés comme ceux de la fonction SQL. Un
/// paramètre à `nil` n'est pas envoyé : la fonction prend alors sa valeur
/// par défaut (`null`).
nonisolated struct JoinOpenGameParams: Encodable, Sendable {
    /// La partie à rejoindre (`reservations.id`).
    let targetReservationId: UUID
    /// `nil` en simple, où la notion d'équipe n'existe pas. En double, `nil`
    /// fait prendre l'équipe A par la base.
    let targetEquipe: String?
    /// Côté souhaité : « gauche », « droite » ou « indifferent ».
    let targetCote: String
    /// Enfant qu'un parent inscrit à sa place ; absent pour soi-même. La base
    /// vérifie le droit (`peut_agir_pour … 'reserver'`).
    var targetProfileId: UUID?

    /// Noms des paramètres de la fonction SQL.
    enum CodingKeys: String, CodingKey {
        case targetReservationId = "target_reservation_id"
        case targetEquipe = "target_equipe"
        case targetCote = "target_cote"
        case targetProfileId = "target_profile_id"
    }
}

/// Paramètre de `leave_open_game`.
nonisolated struct LeaveOpenGameParams: Encodable, Sendable {
    /// La partie à quitter, ou à annuler pour l'hôte.
    let targetReservationId: UUID

    /// Nom du paramètre de la fonction SQL.
    enum CodingKeys: String, CodingKey {
        case targetReservationId = "target_reservation_id"
    }
}

// MARK: - Service

/// Parties ouvertes du club : lecture, adhésion, sortie et création.
enum OpenGameService {

    // MARK: Lecture

    /// Toutes les parties ouvertes confirmées du club, à partir d'aujourd'hui.
    ///
    /// Le tri « complète / commencée » est fait côté domaine : la même lecture
    /// sert à la liste (qui les masque) et à la règle d'une partie par jour
    /// (qui doit les compter).
    ///
    /// Lit d'abord avec le marqueur de pluie. Si la base ne connaît pas la
    /// colonne (`42703`, code PostgreSQL d'une colonne inconnue, relayé par
    /// PostgREST), relit sans elle.
    ///
    /// - Parameter clubId: club du membre connecté.
    /// - Returns: les parties confirmées du jour et des jours suivants, par
    ///   date puis heure de début, complètes et commencées comprises.
    /// - Throws: l'erreur de lecture (réseau, droits), non traduite. Sur la
    ///   première lecture, toute erreur autre que `42703` remonte telle quelle.
    static func loadAll(clubId: UUID) async throws -> [OpenGame] {
        do {
            // Lecture normale : la migration 20261030120000 est appliquée
            // depuis le 30 octobre 2026.
            return try await loadAll(clubId: clubId, columns: OpenGameRow.columnsWithRain)
        } catch let error as PostgrestError where error.code == "42703" {
            // Colonne `sous_reserve_pluie` pas encore créée : la liste reste
            // lisible, simplement sans le badge.
            // Ce repli ne sert plus qu'à une base sans la migration : la même
            // liste, chaque partie avec `isRainReserve` à faux (la clé absente
            // se décode en `nil`). Une erreur de cette seconde lecture remonte
            // telle quelle.
            return try await loadAll(clubId: clubId, columns: OpenGameRow.columns)
        }
    }

    /// Lecture des parties ouvertes avec la liste de colonnes donnée.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - columns: `OpenGameRow.columnsWithRain`, ou `OpenGameRow.columns`
    ///     pour le repli.
    /// - Returns: les parties décodées ; les lignes illisibles sont écartées.
    /// - Throws: l'erreur PostgREST ou réseau.
    private static func loadAll(clubId: UUID, columns: String) async throws -> [OpenGame] {
        // `reservations` du club, parties ouvertes confirmées, du jour de
        // l'appareil et des suivants (borne incluse, sans borne de fin),
        // triées par date puis par heure. Les jointures ramènent le terrain et
        // les joueurs. La RLS ne montre que les réservations des clubs du
        // membre et leurs joueurs ; les terrains sont lisibles par tous.
        // Limite connue : sans pagination, au plus mille lignes.
        let rows: [Lenient<OpenGameRow>] = try await Supa.client
            .from("reservations")
            .select(columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("est_partie_ouverte", value: true)
            .eq("statut", value: ReservationInsert.confirmedStatus)
            .gte("date", value: SupabaseDate.day(from: .now))
            .order("date", ascending: true)
            .order("heure_debut", ascending: true)
            .execute()
            .value

        // Décodage tolérant : une ligne malformée est ignorée (`Lenient`), une
        // ligne incomplète aussi (`toDomain` rend `nil`).
        return rows.compactValues().compactMap { $0.toDomain() }
    }

    // MARK: Adhésion

    /// Inscrit le membre, ou un enfant qu'il gère, dans une partie, par la
    /// fonction `join_open_game` : contrôles et inscription sous verrou.
    ///
    /// Effet de bord : une ligne de `reservation_participants`, écrite par la
    /// fonction. L'appelant relit ensuite la liste et refait les rappels.
    ///
    /// - Parameters:
    ///   - game: la partie visée.
    ///   - team: équipe choisie, transmise en double seulement ; `nil` fait
    ///     prendre l'équipe A par la base.
    ///   - side: côté souhaité (« indifferent » hors padel).
    ///   - childId: profil de l'enfant inscrit à la place du parent ; `nil`
    ///     pour soi-même.
    /// - Throws: `OpenGameError.rejected` avec le message de la base (partie
    ///   complète, déjà commencée ou annulée, mixité, niveau, adultes
    ///   uniquement, une partie par jour, terrain fermé au groupe…), ou
    ///   l'erreur brute.
    static func join(game: OpenGame, team: Team?, side: Side, forChild childId: UUID? = nil) async throws {
        do {
            try await Supa.client
                .rpc("join_open_game", params: JoinOpenGameParams(
                    targetReservationId: game.id,
                    // L'équipe n'est transmise qu'en double.
                    targetEquipe: game.usesTeams ? team?.rawValue : nil,
                    targetCote: side.rawValue,
                    targetProfileId: childId
                ))
                .execute()
        } catch {
            throw translate(error)
        }
    }

    /// Retire le participant, ou annule la partie si l'appelant en est l'hôte.
    /// Une seule fonction couvre les deux cas : il n'y a pas de transfert d'hôte.
    ///
    /// Agit toujours pour le compte connecté (`auth.uid()`), jamais pour un
    /// enfant. Aucun contrôle d'horaire en base : une partie commencée se
    /// quitte aussi ; quitter une partie dont on ne fait pas partie ne fait
    /// rien, sans erreur.
    ///
    /// - Parameter gameId: la partie (`reservations.id`).
    /// - Throws: `OpenGameError.rejected` (« Partie introuvable »…) ou
    ///   l'erreur brute. Le rappel local n'est retiré qu'en cas de succès.
    static func leave(gameId: UUID) async throws {
        do {
            try await Supa.client
                .rpc("leave_open_game", params: LeaveOpenGameParams(targetReservationId: gameId))
                .execute()
            // Partie quittée : son rappel ne doit plus sonner.
            BookingReminders.cancel(reservationId: gameId)
        } catch {
            throw translate(error)
        }
    }

    // MARK: Création

    /// Ouvre une partie : insère la réservation, marquée
    /// `est_partie_ouverte`, puis l'hôte comme premier joueur.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - court: terrain choisi.
    ///   - date: jour de la partie (écrit « AAAA-MM-JJ », fuseau de
    ///     l'appareil).
    ///   - slot: créneau, découpé selon la durée du terrain.
    ///   - format: simple ou double.
    ///   - niveauMin: borne basse de la fourchette, `nil` pour tous niveaux.
    ///   - niveauMax: borne haute, `nil` pour tous niveaux.
    ///   - mixite: qui pourra rejoindre.
    ///   - ambiance: loisir ou compétitif.
    ///   - host: compte connecté, qui devient l'hôte.
    /// - Returns: l'identifiant de la partie créée.
    /// - Throws: `OpenGameError.slotInThePast` (avant tout envoi),
    ///   `.slotAlreadyTaken` (`23505`), `.rejected` (refus P0001 d'un
    ///   déclencheur, par exemple un terrain fermé à un groupe de l'hôte),
    ///   `.hostRegistrationFailed`, ou l'erreur brute de l'insertion.
    static func create(
        clubId: UUID,
        court: Court,
        date: Date,
        slot: TimeSlot,
        format: GameFormat,
        niveauMin: String?,
        niveauMax: String?,
        mixite: Mixite,
        ambiance: Ambiance,
        host: SessionProfile
    ) async throws -> UUID {

        // 1. Le créneau ne doit pas avoir commencé : début calculé dans le
        // fuseau et à l'horloge de l'appareil.
        let start = Calendar.current.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: Calendar.current.startOfDay(for: date)
        ) ?? date
        guard start > .now else { throw OpenGameError.slotInThePast }

        // 2. La ligne de réservation. `sous_reserve_pluie` n'est pas envoyé :
        // le déclencheur du même nom le calcule à l'insertion.
        let payload = OpenGameInsert(
            clubId: clubId,
            courtId: court.id,
            date: SupabaseDate.day(from: date),
            heureDebut: slot.postgresStart,
            // L'heure de fin dérive de la durée du terrain, pas d'une constante.
            heureFin: slot.postgresEnd,
            format: format.rawValue,
            statut: ReservationInsert.confirmedStatus,
            statutPaiement: "inclus",
            montantTotal: 0,
            createdBy: host.id,
            estPartieOuverte: true,
            niveauMin: niveauMin,
            niveauMax: niveauMax,
            mixite: mixite.rawValue,
            ambiance: ambiance.rawValue
        )

        // Insertion, puis relecture du seul identifiant (`select("id")`),
        // nécessaire pour rattacher l'hôte. Les erreurs passent par `translate`.
        let gameId: UUID
        do {
            let inserted: InsertedReservationId = try await Supa.client
                .from("reservations")
                .insert(payload)
                .select("id")
                .single()
                .execute()
                .value
            gameId = inserted.id
        } catch {
            throw translate(error)
        }

        // 3. L'hôte, premier joueur de la partie. Le déclencheur
        // `one_open_game_per_day` peut le refuser.
        do {
            try await Supa.client
                .from("reservation_participants")
                .insert(OpenGameParticipantInsert(
                    reservationId: gameId,
                    profileId: host.id,
                    type: "membre",
                    nomAffiche: host.displayName,
                    supplement: 0,
                    usedCredit: false,
                    // L'hôte prend l'équipe A en double ; aucune en simple.
                    equipe: format == .double ? Team.a.rawValue : nil,
                    cote: Side.indifferent.rawValue
                ))
                .execute()
        } catch {
            // Un créneau bloqué sans joueur est une donnée incohérente.
            // Attention : pour un adhérent, la suppression de rattrapage
            // n'aboutit pas (voir l'en-tête), et le message de la base, même
            // rédigé (P0001), est remplacé par `hostRegistrationFailed`.
            await rollback(gameId: gameId)
            throw OpenGameError.hostRegistrationFailed
        }

        return gameId
    }

    /// Tente de supprimer une partie dont l'hôte n'a pas pu être inscrit.
    ///
    /// Attention : la RLS (`reservations_delete_admin`) réserve la suppression
    /// à l'administration du club. Pour un adhérent, PostgREST ne supprime
    /// rien et ne signale rien ; toute erreur est de toute façon ignorée
    /// (`try?`).
    ///
    /// - Parameter gameId: la réservation à supprimer.
    private static func rollback(gameId: UUID) async {
        _ = try? await Supa.client
            .from("reservations")
            .delete()
            .eq("id", value: gameId.uuidString)
            .execute()
    }

    // MARK: Erreurs

    /// Code PostgreSQL d'une violation d'unicité : ici, l'index
    /// `reservations_no_double_booking` (créneau déjà pris).
    private static let uniqueViolation = "23505"
    /// `RAISE EXCEPTION` dans une fonction PL/pgSQL : message métier déjà rédigé.
    /// C'est aussi le code par défaut d'un `RAISE EXCEPTION` sans `errcode`,
    /// cas de la plupart des refus de `join_open_game`.
    private static let businessError = "P0001"

    /// Traduit une erreur de la base en `OpenGameError` quand c'est possible.
    ///
    /// - Parameter error: l'erreur rendue par le client Supabase.
    /// - Returns: `.slotAlreadyTaken` pour une violation d'unicité,
    ///   `.rejected` avec le message de la base pour un refus métier (P0001),
    ///   l'erreur d'origine sinon (message technique, non traduit).
    private static func translate(_ error: any Error) -> any Error {
        // Une erreur qui ne vient pas de PostgREST (réseau, décodage) remonte
        // telle quelle.
        guard let postgrest = error as? PostgrestError else { return error }

        // Codes connus : créneau pris, refus rédigé par la base.
        if postgrest.code == uniqueViolation { return OpenGameError.slotAlreadyTaken }
        if postgrest.code == businessError { return OpenGameError.rejected(postgrest.message) }

        // Filet de sécurité : une erreur PostgREST sans ce code, mais dont le
        // texte parle d'une violation d'unicité.
        let description = String(describing: error).lowercased()
        if description.contains(uniqueViolation) || description.contains("duplicate key") {
            return OpenGameError.slotAlreadyTaken
        }

        // Tout le reste (contrainte `check`, droits refusés…) : l'erreur brute.
        return error
    }
}
