//
//  BookingDraft.swift
//  iClub
//
//  État du tunnel entre le choix du terrain et la confirmation : format,
//  participants, crédits invités, mode de paiement.
//
//  Volontairement *pas* de minuteur « créneau retenu 8 min » comme le web :
//  aucun verrou n'existe côté serveur, la seule protection réelle est la
//  contrainte d'unicité au moment de confirmer. Un compte à rebours mettrait
//  une pression artificielle sur l'utilisateur sans rien garantir.
//

import Foundation
import Observation

@Observable
final class BookingDraft {

    // MARK: - Contexte

    private(set) var court: Court?
    private(set) var date: Date = .now
    private(set) var slot: TimeSlot = TimeSlot(startMinutes: 0, durationMinutes: 60)
    private(set) var sport: Sport = .tennis

    // MARK: - Composition

    var format: GameFormat = .simple
    private(set) var participants: [BookingParticipant] = []

    /// Solde de crédits hors panier en cours, recalculé à l'ouverture.
    private(set) var credits: GuestCreditBalance = .none

    var paymentMode: PaymentMode = .carte
    var acceptsTerms = true

    // MARK: - Ouverture

    /// Réinitialise le brouillon pour un nouveau tunnel. Le réservataire est
    /// ajouté d'emblée : il est toujours le premier participant.
    func start(court: Court, date: Date, slot: TimeSlot, sport: Sport, profile: SessionProfile) {
        self.court = court
        self.date = date
        self.slot = slot
        self.sport = sport

        format = GameFormat.preferred(for: sport)
        participants = [.owner(profile)]
        credits = .none
        paymentMode = .carte
        acceptsTerms = true
    }

    /// Charge le solde de crédits. Séparé de `start` pour que l'écran s'affiche
    /// immédiatement, sans attendre le réseau.
    func loadCredits(profile: SessionProfile) async {
        credits = await GuestCreditService.balance(
            clubId: profile.clubId,
            clubMemberId: profile.clubMemberId,
            profileId: profile.id,
            period: profile.activeMembershipPeriod
        )
    }

    // MARK: - Format

    /// Repasser de double à simple avec 4 joueurs déjà listés retire les
    /// participants excédentaires en partant de la fin — jamais le réservataire,
    /// qui est en tête de liste.
    func setFormat(_ newFormat: GameFormat) {
        format = newFormat
        while participants.count > newFormat.capacity, participants.count > 1 {
            participants.removeLast()
        }
    }

    // MARK: - Participants

    var capacity: Int { format.capacity }
    var missingCount: Int { max(0, capacity - participants.count) }
    var isComplete: Bool { missingCount == 0 }
    var hasRoom: Bool { participants.count < capacity }

    /// Profils déjà dans la liste, pour les écarter des résultats de recherche.
    var takenProfileIds: Set<UUID> {
        Set(participants.compactMap(\.profileId))
    }

    func add(member: MemberSearchResult) {
        guard hasRoom, !takenProfileIds.contains(member.profileId) else { return }
        participants.append(.member(member))
    }

    func add(guestPrenom: String, nom: String, payer: GuestPayer) {
        guard hasRoom else { return }
        participants.append(.guest(prenom: guestPrenom, nom: nom, payer: payer))
    }

    /// Retirer un invité sur crédit rend ce crédit immédiatement : le solde
    /// affiché est dérivé de la liste, il n'y a aucun compteur à décrémenter.
    func remove(_ participant: BookingParticipant) {
        guard participant.isRemovable else { return }
        participants.removeAll { $0.id == participant.id }
    }

    // MARK: - Crédits

    /// Crédits consommés par le panier en cours.
    var creditsInBasket: Int {
        participants.filter(\.usesCredit).count
    }

    /// Crédits encore disponibles, panier déduit.
    var creditsRemaining: Int {
        max(0, credits.available - creditsInBasket)
    }

    /// Choix présélectionné pour un nouvel invité : le crédit s'il en reste,
    /// sinon le supplément.
    var preferredGuestPayer: GuestPayer {
        creditsRemaining > 0 ? .credit : .supplement
    }

    // MARK: - Montant

    /// Total à régler : la somme des suppléments. Les adhérents sont inclus
    /// dans leur cotisation, les invités sur crédit sont gratuits.
    var total: Double {
        participants.reduce(0) { $0 + $1.supplement }
    }

    var requiresPayment: Bool { total > 0 }

    /// Libellé du bouton final.
    var confirmTitle: String {
        requiresPayment ? "Payer \(Price.amount(total))" : "Confirmer la réservation"
    }

    var canConfirm: Bool {
        isComplete && acceptsTerms && court != nil
    }
}
