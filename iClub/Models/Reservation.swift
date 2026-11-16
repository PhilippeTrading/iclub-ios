//
//  Reservation.swift
//  iClub
//
//  Lecture et écriture de `reservations` et `reservation_participants`.
//
//  Seules les lignes `statut = 'confirmee'` occupent un créneau : une
//  réservation annulée le libère, et n'est pas supprimée. Elle reste en base
//  avec son `cancelled_at`, dont dépend la restitution du crédit invité.
//
//  Rôle
//    DTO de lecture des réservations du jour (`ReservationRow`, pour le
//    planning), charges utiles d'écriture (réservation, participants,
//    annulation) et modes de paiement proposés dans le tunnel.
//
//  Place dans l'application
//    `PlanningService.loadReservations` (lecture), `ReservationService.confirm`
//    et `ReservationService.cancel` (écritures).
//
//  Droits et sécurité (RLS de la base)
//    - Lecture des réservations : tout membre du club (`reservations_select_club`).
//    - Création : par soi-même (`created_by = auth.uid()`) ou par
//      l'administration (`reservations_insert`).
//    - Modification : par le créateur ou l'administration ; suppression :
//      administration seulement.
//    - Participants : écrits par le créateur de la réservation ou
//      l'administration (`reservation_participants_write`).
//    Déclencheurs à l'insertion : `acces_terrain` (terrain fermé au groupe du
//    réservataire, refus P0001) et `sous_reserve_pluie` (marqueur posé par la
//    base) sur `reservations` ; `one_open_game_per_day`, `acces_terrain_partie`
//    et `trg_notifications_rejointes` sur `reservation_participants` (ils ne
//    concernent que les parties ouvertes).
//
//  Points d'attention
//    Attention : les valeurs de paiement écrites ici ne correspondent plus aux
//    contraintes de la base depuis la migration
//    `20261021170000_reservations_paiement.sql` (voir `paymentStatus(total:)`
//    et `PaymentMode`). Toute réservation avec un montant à régler est alors
//    refusée par la base.
//

import Foundation

// MARK: - Lecture (disponibilités)

/// Réservation confirmée du jour, réduite à ce qui occupe une case du planning.
nonisolated struct ReservationRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `court_id` : terrain occupé.
    let courtId: UUID
    /// `heure_debut` (`time`), en texte.
    let heureDebut: String?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id
        case courtId = "court_id"
        case heureDebut = "heure_debut"
    }

    /// Colonnes demandées : le strict nécessaire, car la lecture est relancée à
    /// chaque événement temps réel.
    static let columns = "id, court_id, heure_debut"

    /// Début de la réservation, en minutes depuis minuit.
    var startMinutes: Int? {
        ClubSportSettingsRow.minutes(from: heureDebut)
    }
}

// MARK: - Écriture

/// Charge utile d'insertion. `statut` est écrit explicitement plutôt que laissé
/// au défaut de la base, pour que la ligne créée par l'app soit identique à
/// celle créée par le web.
///
/// Ni `est_partie_ouverte` (défaut `false` : réservation classique) ni
/// `on_behalf_of_club_member_id` ne sont envoyés. Une réservation faite au nom
/// d'un enfant porte donc le parent comme seul titulaire en base ; l'app vérifie
/// au préalable les terrains fermés à l'enfant (`terrains_interdits`).
nonisolated struct ReservationInsert: Encodable, Sendable {
    /// `club_id`.
    let clubId: UUID
    /// `court_id`.
    let courtId: UUID
    /// `date` : jour, « AAAA-MM-JJ » dans le fuseau de l'appareil.
    let date: String
    /// `heure_debut` : « HH:MM:00 ».
    let heureDebut: String
    /// `heure_fin` : début plus la durée de créneau du terrain.
    let heureFin: String
    /// `format` : `simple` ou `double`.
    let format: String
    /// `statut` : toujours `confirmee` à la création.
    let statut: String
    /// `statut_paiement` (voir `paymentStatus(total:)`).
    let statutPaiement: String
    /// `montant_total`, en euros : somme des suppléments des participants.
    let montantTotal: Double
    /// `nil` quand rien n'est à régler : aucun mode de paiement n'a de sens.
    /// Sinon la valeur brute d'un `PaymentMode` (`mode_paiement`).
    let modePaiement: String?
    /// `created_by` : le compte connecté (jamais l'enfant, qui n'a pas de
    /// session). La RLS exige qu'il soit l'utilisateur de la session.
    let createdBy: UUID

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case date, format, statut
        case clubId = "club_id"
        case courtId = "court_id"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case statutPaiement = "statut_paiement"
        case montantTotal = "montant_total"
        case modePaiement = "mode_paiement"
        case createdBy = "created_by"
    }

    /// Valeur de `statut` d'une réservation qui occupe son créneau.
    static let confirmedStatus = "confirmee"
    /// Valeur de `statut` d'une réservation annulée (la ligne est conservée).
    static let cancelledStatus = "annulee"

    /// `statut_paiement` : « payé » dès qu'un supplément est dû, « inclus »
    /// quand la partie est couverte par les adhésions.
    ///
    /// Attention : depuis la migration `20261021170000_reservations_paiement.sql`,
    /// la colonne n'accepte plus que `inclus`, `a_regler`, `regle` et
    /// `rembourse` (contrainte `reservations_statut_paiement_check`) ; le web
    /// écrit `a_regler` quand un montant est dû. La valeur `paye` écrite ici fait
    /// refuser l'insertion par la base (violation de contrainte `check`).
    ///
    /// - Parameter total: montant dû, en euros.
    /// - Returns: `paye` si le montant est positif, `inclus` sinon.
    static func paymentStatus(total: Double) -> String {
        total > 0 ? "paye" : "inclus"
    }
}

/// Une ligne par participant. L'insertion se fait en lot, après la réservation.
nonisolated struct ReservationParticipantInsert: Encodable, Sendable {
    /// `reservation_id` : la réservation qui vient d'être créée.
    let reservationId: UUID
    /// `nil` pour un invité non-membre.
    /// (`profile_id`.)
    let profileId: UUID?
    /// `type` : `membre` ou `invite` (voir `BookingParticipant.Kind.storedType`).
    let type: String
    /// `nom_affiche` : nom montré dans les listes, y compris pour un invité.
    let nomAffiche: String
    /// `supplement`, en euros : part due par ce participant (0 sauf invité au
    /// supplément).
    let supplement: Double
    /// `used_credit` : la place de cet invité est prise sur un crédit invité du
    /// réservataire.
    let usedCredit: Bool

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case type, supplement
        case reservationId = "reservation_id"
        case profileId = "profile_id"
        case nomAffiche = "nom_affiche"
        case usedCredit = "used_credit"
    }
}

/// Mise à jour d'annulation. La ligne est conservée : c'est `cancelled_at` qui
/// détermine si le crédit invité est restitué.
nonisolated struct ReservationCancelUpdate: Encodable, Sendable {
    /// `statut` : `annulee`.
    let statut: String
    /// `cancelled_at` : instant de l'annulation, ISO 8601 en temps universel.
    let cancelledAt: String
    /// `cancelled_by` : profil qui annule.
    let cancelledBy: UUID

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case statut
        case cancelledAt = "cancelled_at"
        case cancelledBy = "cancelled_by"
    }

    /// - Parameters:
    ///   - profileId: profil qui annule (le compte connecté).
    ///   - date: instant de l'annulation, maintenant par défaut.
    init(by profileId: UUID, at date: Date = .now) {
        self.statut = ReservationInsert.cancelledStatus
        self.cancelledAt = date.formatted(.iso8601)
        self.cancelledBy = profileId
    }
}

/// Identifiant renvoyé par l'insertion, nécessaire pour rattacher les
/// participants et pour pouvoir supprimer la réservation si leur insertion échoue.
nonisolated struct InsertedReservationId: Decodable, Sendable {
    /// `id` de la réservation créée.
    let id: UUID
}

// MARK: - Mode de paiement

/// Aucune intégration bancaire n'est branchée : ce sont des intentions
/// enregistrées en base, que le club traite ensuite.
///
/// Attention : les valeurs brutes (`carte`, `lien`, `surplace`) ne figurent pas
/// parmi celles qu'accepte `reservations.mode_paiement` (`null`, `cb`,
/// `especes`, `cheque`, `en_ligne`, `wallet`, `credit`, `virement`, `mixte`,
/// contrainte posée par `20261022100000_parite_doinsport.sql`). Même la
/// contrainte d'origine attendait `sur_place`, avec un trait de soulignement.
/// Le web, lui, écrit `null` à la création.
nonisolated enum PaymentMode: String, CaseIterable, Identifiable, Sendable {
    /// Paiement immédiat par carte.
    case carte
    /// Lien de paiement envoyé à l'invité.
    case lien
    /// Règlement au club.
    case surplace

    /// Identifiant de liste : la valeur brute.
    var id: String { rawValue }

    /// Libellé du choix dans le récapitulatif.
    var displayName: String {
        switch self {
        case .carte: "Payer maintenant par carte"
        case .lien: "Envoyer le lien de paiement à l'invité"
        case .surplace: "Payer sur place"
        }
    }

    /// Pictogramme SF Symbols du choix.
    var systemImage: String {
        switch self {
        case .carte: "creditcard"
        case .lien: "paperplane"
        case .surplace: "building.2"
        }
    }
}
