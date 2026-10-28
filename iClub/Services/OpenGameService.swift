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
//  affichées telles quelles — les vérifications côté app ne servent qu'à
//  éviter l'aller-retour, pas à remplacer celles de la base.
//

import Foundation
import Supabase

enum OpenGameError: LocalizedError {
    /// Refus métier venant de la base, déjà rédigé.
    case rejected(String)
    /// Le créneau visé est déjà passé.
    case slotInThePast
    /// Contrainte d'unicité : quelqu'un vient de réserver ce créneau.
    case slotAlreadyTaken
    /// L'hôte n'a pas pu être enregistré ; la partie a été supprimée.
    case hostRegistrationFailed

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
nonisolated struct OpenGameInsert: Encodable, Sendable {
    let clubId: UUID
    let courtId: UUID
    let date: String
    let heureDebut: String
    let heureFin: String
    let format: String
    let statut: String
    let statutPaiement: String
    let montantTotal: Double
    let createdBy: UUID
    let estPartieOuverte: Bool
    let niveauMin: String?
    let niveauMax: String?
    let mixite: String
    let ambiance: String

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
    let reservationId: UUID
    let profileId: UUID
    let type: String
    let nomAffiche: String
    let supplement: Double
    let usedCredit: Bool
    let equipe: String?
    let cote: String

    enum CodingKeys: String, CodingKey {
        case type, supplement, equipe, cote
        case reservationId = "reservation_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case usedCredit = "used_credit"
    }
}

nonisolated struct JoinOpenGameParams: Encodable, Sendable {
    let targetReservationId: UUID
    /// `nil` en simple, où la notion d'équipe n'existe pas.
    let targetEquipe: String?
    let targetCote: String
    /// Enfant qu'un parent inscrit à sa place ; absent pour soi-même. La base
    /// vérifie le droit (`peut_agir_pour … 'reserver'`).
    var targetProfileId: UUID?

    enum CodingKeys: String, CodingKey {
        case targetReservationId = "target_reservation_id"
        case targetEquipe = "target_equipe"
        case targetCote = "target_cote"
        case targetProfileId = "target_profile_id"
    }
}

nonisolated struct LeaveOpenGameParams: Encodable, Sendable {
    let targetReservationId: UUID

    enum CodingKeys: String, CodingKey {
        case targetReservationId = "target_reservation_id"
    }
}

// MARK: - Service

enum OpenGameService {

    // MARK: Lecture

    /// Toutes les parties ouvertes confirmées du club, à partir d'aujourd'hui.
    ///
    /// Le tri « complète / commencée » est fait côté domaine : la même lecture
    /// sert à la liste (qui les masque) et à la règle d'une partie par jour
    /// (qui doit les compter).
    static func loadAll(clubId: UUID) async throws -> [OpenGame] {
        let rows: [Lenient<OpenGameRow>] = try await Supa.client
            .from("reservations")
            .select(OpenGameRow.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("est_partie_ouverte", value: true)
            .eq("statut", value: ReservationInsert.confirmedStatus)
            .gte("date", value: SupabaseDate.day(from: .now))
            .order("date", ascending: true)
            .order("heure_debut", ascending: true)
            .execute()
            .value

        return rows.compactValues().compactMap { $0.toDomain() }
    }

    // MARK: Adhésion

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
    /// Une seule fonction couvre les deux cas — il n'y a pas de transfert d'hôte.
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

    /// - Returns: l'identifiant de la partie créée.
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

        let start = Calendar.current.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: Calendar.current.startOfDay(for: date)
        ) ?? date
        guard start > .now else { throw OpenGameError.slotInThePast }

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
            await rollback(gameId: gameId)
            throw OpenGameError.hostRegistrationFailed
        }

        return gameId
    }

    private static func rollback(gameId: UUID) async {
        _ = try? await Supa.client
            .from("reservations")
            .delete()
            .eq("id", value: gameId.uuidString)
            .execute()
    }

    // MARK: Erreurs

    private static let uniqueViolation = "23505"
    /// `RAISE EXCEPTION` dans une fonction PL/pgSQL : message métier déjà rédigé.
    private static let businessError = "P0001"

    private static func translate(_ error: any Error) -> any Error {
        guard let postgrest = error as? PostgrestError else { return error }

        if postgrest.code == uniqueViolation { return OpenGameError.slotAlreadyTaken }
        if postgrest.code == businessError { return OpenGameError.rejected(postgrest.message) }

        let description = String(describing: error).lowercased()
        if description.contains(uniqueViolation) || description.contains("duplicate key") {
            return OpenGameError.slotAlreadyTaken
        }

        return error
    }
}
