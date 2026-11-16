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
//  créneau reçoit un `23505`, traduit en message lisible, jamais remonté brut.
//
//  Place dans l'application
//    Récapitulatif du tunnel (`BookingSummaryView`, confirmation), accueil,
//    historique et détail d'une réservation (annulation, liste « mes
//    réservations »), rappels locaux (`BookingReminders`).
//
//  Tables et garanties de la base
//    - `reservations` : insertion par soi-même (`created_by = auth.uid()`),
//      modification par le créateur ou l'administration, suppression par
//      l'administration seulement (RLS `reservations_delete_admin`).
//      Déclencheurs à l'insertion : `acces_terrain` (terrain fermé à un groupe
//      du réservataire, refus P0001 au message rédigé) et `sous_reserve_pluie`.
//      Index unique `reservations_no_double_booking` (créneau déjà pris).
//    - `reservation_participants` : écriture par le créateur de la réservation.
//
//  Points d'attention
//    - Attention : `ReservationInsert` écrit `statut_paiement = 'paye'` et un
//      `mode_paiement` (`carte`, `lien`, `surplace`) qui ne respectent plus les
//      contraintes de la base (voir Reservation.swift). Une réservation avec un
//      montant à régler est donc refusée par la base, avec une erreur technique
//      que `translate` ne reconnaît pas.
//    - Attention : la suppression de rattrapage est réservée par la RLS à
//      l'administration du club. Pour un adhérent, elle ne supprime rien, sans
//      erreur : la réservation reste confirmée, sans participants (le web a la
//      même limite).
//    - Le web vérifie en plus qu'aucune réservation ni aucun blocage ne
//      chevauche le créneau sur toute sa durée ; l'app s'en remet à l'index
//      unique, qui ne voit que l'heure de début.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//

import Foundation
import Supabase

/// Erreurs de réservation, avec leur message affichable.
enum ReservationError: LocalizedError, Equatable {
    /// Quelqu'un a confirmé le même créneau entre l'affichage et le tap.
    case slotAlreadyTaken
    /// Les participants n'ont pas pu être enregistrés ; la réservation a été
    /// annulée pour ne pas laisser de donnée incohérente.
    /// (Voir l'avertissement de l'en-tête : pour un adhérent, la suppression de
    /// rattrapage n'aboutit pas.)
    case participantsFailed
    /// Refus de la base (P0001), à afficher tel quel : par exemple « Vous ne
    /// pouvez pas réserver ce terrain. Pour en savoir plus, contactez le club. »
    case refused(String)

    /// Message montré sur le récapitulatif.
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

/// Réservations de terrain du membre.
enum ReservationService {

    // MARK: - Confirmation

    /// Enregistre une réservation et ses participants.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - court: terrain réservé.
    ///   - date: jour (écrit « AAAA-MM-JJ », fuseau de l'appareil).
    ///   - slot: créneau (début et durée du terrain).
    ///   - format: simple ou double.
    ///   - participants: joueurs, réservataire en premier.
    ///   - total: montant à régler, en euros (somme des suppléments).
    ///   - paymentMode: mode de paiement choisi, `nil` si rien n'est dû.
    ///   - createdBy: compte connecté (`created_by`).
    /// - Returns: l'identifiant de la réservation créée.
    /// - Throws: `ReservationError` (créneau pris, refus de la base,
    ///   participants refusés) ou l'erreur brute de l'insertion.
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

        // 1. La réservation (les erreurs sont traduites par `translate`).
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

        // 2. Les participants, en un seul lot ; en cas d'échec, rattrapage.
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

    /// Insère la ligne `reservations` et rend son identifiant.
    ///
    /// - Returns: `reservations.id` de la ligne créée.
    /// - Throws: l'erreur traduite par `translate`.
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
            // Pas de mode de paiement quand rien n'est dû.
            modePaiement: total > 0 ? paymentMode?.rawValue : nil,
            createdBy: createdBy
        )

        do {
            // `.select("id").single()` : la ligne créée est rendue, pour
            // rattacher les participants.
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

    /// Insère les participants en un seul appel.
    ///
    /// - Parameters:
    ///   - reservationId: réservation qui vient d'être créée.
    ///   - participants: joueurs à enregistrer.
    /// - Throws: l'erreur brute de l'insertion.
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
    ///
    /// Attention : un refus de la RLS (suppression réservée à
    /// l'administration) n'est pas une erreur pour PostgREST ; il passe donc
    /// inaperçu ici.
    ///
    /// - Parameter reservationId: réservation à supprimer.
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
    /// restitué de lui-même puisque le solde est recalculé, jamais stocké
    /// (sous réserve de la règle des 2 heures, voir `CreditUsageRow`).
    ///
    /// Attention : sans `.select()` après la mise à jour, une annulation refusée
    /// par la RLS (réservation créée par quelqu'un d'autre) ne touche aucune
    /// ligne sans lever d'erreur : l'écran la croit réussie, et le rappel local
    /// est retiré quand même.
    ///
    /// - Parameters:
    ///   - reservationId: réservation à annuler.
    ///   - profileId: compte qui annule (`cancelled_by`).
    /// - Throws: l'erreur brute de la requête.
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
    ///
    /// Limite connue : aucune pagination ; au-delà de la limite de lignes de
    /// l'API (mille par défaut sur Supabase), la liste serait tronquée. La
    /// liste des réservations jointes est aussi recopiée dans l'adresse de la
    /// requête, qui s'allonge avec l'historique du membre.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - profileId: profil du membre.
    /// - Returns: réservations annulées comprises, triées par date puis heure ;
    ///   une ligne sans date ou heure lisible est écartée.
    /// - Throws: l'erreur brute de l'une des deux requêtes.
    static func loadMine(clubId: UUID, profileId: UUID) async throws -> [MyReservation] {
        // 1. Les réservations où je suis joueur (créées ou non par moi).
        let joinedIds = try await joinedReservationIds(profileId: profileId)

        // 2. Les réservations elles-mêmes, avec terrain et participants.
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
            // Créées par moi OU dont je suis participant (filtre `or` PostgREST).
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

    /// Réservations où le profil figure comme participant, sans doublon.
    ///
    /// - Parameter profileId: profil du membre.
    /// - Returns: identifiants de réservations (tous clubs confondus ; le
    ///   filtre par club est fait par la requête suivante).
    /// - Throws: l'erreur brute de la requête.
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

    /// Traduit une erreur d'insertion de réservation.
    ///
    /// - Parameter error: erreur du SDK.
    /// - Returns: `slotAlreadyTaken` pour une violation d'unicité (créneau
    ///   pris), `refused` pour un refus rédigé de la base (P0001, par exemple
    ///   un terrain fermé à un groupe), l'erreur d'origine sinon (dont les
    ///   violations de contrainte `check`, code 23514).
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
