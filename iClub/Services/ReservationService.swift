//
//  ReservationService.swift
//  iClub
//
//  Écriture, annulation et lecture des réservations de l'utilisateur.
//
//  La confirmation est en deux insertions, la seconde dépendant de la
//  première. PostgREST n'offre pas de transaction sur deux appels : si les
//  participants échouent, on supprime la réservation qui vient d'être créée.
//  Une réservation sans participants occuperait un créneau pour rien.
//
//  La base porte une contrainte d'unicité sur `(court_id, date, heure_debut)`
//  pour les réservations confirmées. La seconde personne à confirmer le même
//  créneau reçoit un `23505`, traduit en message lisible — jamais remonté brut.
//

import Foundation
import Supabase

enum ReservationError: LocalizedError, Equatable {
    /// Quelqu'un a confirmé le même créneau entre l'affichage et le tap.
    case slotAlreadyTaken
    /// Les participants n'ont pas pu être enregistrés ; la réservation a été
    /// annulée pour ne pas laisser de donnée incohérente.
    case participantsFailed
    /// Refus de la base (P0001), à afficher tel quel : par exemple « Vous ne
    /// pouvez pas réserver ce terrain. Pour en savoir plus, contactez le club. »
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let message):
            message
        case .slotAlreadyTaken:
            "Ce créneau vient d'être réservé par quelqu'un d'autre — choisissez-en un autre."
        case .participantsFailed:
            "Les participants n'ont pas pu être enregistrés. La réservation a été annulée, réessaie."
        }
    }
}

enum ReservationService {

    // MARK: - Confirmation

    /// - Returns: l'identifiant de la réservation créée.
    static func confirm(
        clubId: UUID,
        court: Court,
        date: Date,
        slot: TimeSlot,
        format: GameFormat,
        participants: [BookingParticipant],
        total: Double,
        paymentMode: PaymentMode?,
        createdBy: UUID
    ) async throws -> UUID {

        let reservationId = try await insertReservation(
            clubId: clubId,
            court: court,
            date: date,
            slot: slot,
            format: format,
            total: total,
            paymentMode: paymentMode,
            createdBy: createdBy
        )

        do {
            try await insertParticipants(reservationId: reservationId, participants: participants)
        } catch {
            await rollback(reservationId: reservationId)
            // Un joueur refusé par la base (terrain fermé à un enfant, par
            // exemple) : son message, tel quel.
            if let postgrest = error as? PostgrestError, postgrest.code == "P0001" {
                throw ReservationError.refused(postgrest.message)
            }
            throw ReservationError.participantsFailed
        }

        return reservationId
    }

    private static func insertReservation(
        clubId: UUID,
        court: Court,
        date: Date,
        slot: TimeSlot,
        format: GameFormat,
        total: Double,
        paymentMode: PaymentMode?,
        createdBy: UUID
    ) async throws -> UUID {
        let payload = ReservationInsert(
            clubId: clubId,
            courtId: court.id,
            date: SupabaseDate.day(from: date),
            heureDebut: slot.postgresStart,
            // L'heure de fin dérive de la durée de créneau du terrain, pas
            // d'une constante : 60 min en tennis, 90 en padel.
            heureFin: slot.postgresEnd,
            format: format.rawValue,
            statut: ReservationInsert.confirmedStatus,
            statutPaiement: ReservationInsert.paymentStatus(total: total),
            montantTotal: total,
            modePaiement: total > 0 ? paymentMode?.rawValue : nil,
            createdBy: createdBy
        )

        do {
            let inserted: InsertedReservationId = try await Supa.client
                .from("reservations")
                .insert(payload)
                .select("id")
                .single()
                .execute()
                .value

            return inserted.id
        } catch {
            throw translate(error)
        }
    }

    private static func insertParticipants(
        reservationId: UUID,
        participants: [BookingParticipant]
    ) async throws {
        let payload = participants.map { participant in
            ReservationParticipantInsert(
                reservationId: reservationId,
                profileId: participant.profileId,
                type: participant.kind.storedType,
                nomAffiche: participant.displayName,
                supplement: participant.supplement,
                usedCredit: participant.usesCredit
            )
        }

        try await Supa.client
            .from("reservation_participants")
            .insert(payload)
            .execute()
    }

    /// Suppression de rattrapage. Un échec ici ne peut plus être corrigé côté
    /// app : c'est l'erreur d'origine qui est remontée à l'utilisateur.
    private static func rollback(reservationId: UUID) async {
        _ = try? await Supa.client
            .from("reservations")
            .delete()
            .eq("id", value: reservationId.uuidString)
            .execute()
    }

    // MARK: - Annulation

    /// L'annulation ne supprime pas la ligne : elle la met à jour. Le créneau
    /// redevient disponible pour tout le monde, et le crédit invité est
    /// restitué de lui-même puisque le solde est recalculé, jamais stocké.
    static func cancel(reservationId: UUID, by profileId: UUID) async throws {
        try await Supa.client
            .from("reservations")
            .update(ReservationCancelUpdate(by: profileId))
            .eq("id", value: reservationId.uuidString)
            .execute()
        // Annulée : son rappel ne doit plus sonner.
        BookingReminders.cancel(reservationId: reservationId)
    }

    // MARK: - Mes réservations

    /// Réservations où je figure comme créateur **ou** comme participant.
    static func loadMine(clubId: UUID, profileId: UUID) async throws -> [MyReservation] {
        let joinedIds = try await joinedReservationIds(profileId: profileId)

        let query = Supa.client
            .from("reservations")
            .select(MyReservationRow.columns)
            .eq("club_id", value: clubId.uuidString)

        // `id.in.()` avec une liste vide est un filtre invalide : quand je ne
        // participe à rien, on se limite à ce que j'ai créé.
        let rows: [Lenient<MyReservationRow>]
        if joinedIds.isEmpty {
            rows = try await query
                .eq("created_by", value: profileId.uuidString)
                .order("date", ascending: true)
                .order("heure_debut", ascending: true)
                .execute()
                .value
        } else {
            let list = joinedIds.map(\.uuidString).joined(separator: ",")
            rows = try await query
                .or("created_by.eq.\(profileId.uuidString),id.in.(\(list))")
                .order("date", ascending: true)
                .order("heure_debut", ascending: true)
                .execute()
                .value
        }

        return rows.compactValues().compactMap { $0.toDomain(myProfileId: profileId) }
    }

    private static func joinedReservationIds(profileId: UUID) async throws -> [UUID] {
        let rows: [Lenient<ParticipationRow>] = try await Supa.client
            .from("reservation_participants")
            .select(ParticipationRow.columns)
            .eq("profile_id", value: profileId.uuidString)
            .execute()
            .value

        return Array(Set(rows.compactValues().map(\.reservationId)))
    }

    // MARK: - Erreurs

    /// SQLSTATE d'une violation de contrainte d'unicité.
    private static let uniqueViolation = "23505"

    private static func translate(_ error: any Error) -> any Error {
        if let postgrest = error as? PostgrestError, postgrest.code == uniqueViolation {
            return ReservationError.slotAlreadyTaken
        }
        if let postgrest = error as? PostgrestError, postgrest.code == "P0001" {
            return ReservationError.refused(postgrest.message)
        }

        // Selon la configuration de PostgREST, la violation arrive parfois sans
        // code exploitable : on la reconnaît alors dans le message.
        let description = String(describing: error).lowercased()
        if description.contains(uniqueViolation) || description.contains("duplicate key") {
            return ReservationError.slotAlreadyTaken
        }

        return error
    }
}
