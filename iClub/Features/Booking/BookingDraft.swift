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
//  Place dans l'application
//    Un seul brouillon par tunnel, créé par `BookingView` (racine de l'onglet
//    « Réserver ») et passé aux écrans suivants : `CourtPickerView` le
//    réinitialise au choix du terrain (`start`), `ParticipantsView` le
//    compose, `BookingSummaryView` choisit le mode de paiement, fait cocher
//    les conditions puis confirme par `ReservationService.confirm`.
//
//  Règles appliquées ici
//    - Le premier joueur est la personne au nom de qui l'on réserve (soi, ou
//      l'enfant sélectionné), non supprimable.
//    - Capacité du format : 2 joueurs en simple, 4 en double ; le padel est
//      toujours en double. La liste doit être complète pour continuer.
//    - Un invité est gratuit sur crédit (s'il en reste sur la période
//      d'adhésion), sinon il coûte le supplément de 10 €
//      (`BookingPricing.guestSupplement`). Le total est la somme des
//      suppléments ; un adhérent ne coûte rien.
//
//  Ce que la base revérifie à la confirmation, et ce qu'elle ne revérifie pas
//    - Revérifié : créneau non déjà pris à la même heure de début (index unique
//      `reservations_no_double_booking`, erreur 23505), accès du réservataire
//      au terrain (déclencheur `acces_terrain`), droit d'écrire
//      (RLS : `created_by` doit être le compte connecté).
//    - Non revérifié : solde de crédits invités, montant des suppléments,
//      horizon de réservation, créneau passé, chevauchement avec un blocage.
//      Ces règles ne tiennent qu'à l'app.
//
//  Points d'attention
//    - Attention : avec un supplément (total supérieur à zéro), l'insertion
//      écrit `statut_paiement = 'paye'` et un `mode_paiement` (« carte »,
//      « lien » ou « surplace ») que les contraintes actuelles de la table
//      `reservations` refusent (migrations 20261021170000 et 20261022100000 :
//      « a_regler » ou « regle », et « cb », « especes »...). La confirmation
//      d'une réservation avec invité au supplément échoue donc, avec un
//      message technique.
//    - Attention : si l'enregistrement des joueurs échoue après celui de la
//      réservation, `ReservationService` tente de supprimer la réservation,
//      mais la RLS (`reservations_delete_admin`) réserve la suppression aux
//      administrateurs : pour un membre, la réservation reste confirmée, sans
//      joueur, et occupe le créneau.
//    - Écart avec le web : le serveur web fait payer sa part à un membre sans
//      adhésion à jour ; ici, un tel membre est seulement signalé (« Sans
//      adhésion active ») et ne coûte rien.
//    - Quand on réserve pour un enfant, le créateur reste le compte connecté
//      et la réservation ne renseigne pas `on_behalf_of_club_member_id` : le
//      déclencheur d'accès contrôle donc les groupes du parent, et seul le
//      contrôle fait par l'app avant l'envoi (`BookingSummaryView`) protège
//      les terrains fermés à l'enfant.
//

import Foundation
import Observation

/// Brouillon observable d'une réservation en cours de composition.
@Observable
final class BookingDraft {

    // MARK: - Contexte

    /// Terrain choisi ; `nil` tant que `start` n'a pas été appelé.
    private(set) var court: Court?
    /// Jour de la réservation (fuseau de l'appareil).
    private(set) var date: Date = .now
    /// Créneau choisi (minutes depuis minuit) ; valeur de départ sans
    /// signification avant `start`.
    private(set) var slot: TimeSlot = TimeSlot(startMinutes: 0, durationMinutes: 60)
    /// Sport du terrain choisi.
    private(set) var sport: Sport = .tennis

    // MARK: - Composition

    /// Format de jeu ; à modifier par `setFormat` pour ajuster la liste.
    var format: GameFormat = .simple
    /// Joueurs, le réservataire en tête. Modifiés seulement par les méthodes
    /// ci-dessous.
    private(set) var participants: [BookingParticipant] = []

    /// Solde de crédits hors panier en cours, recalculé à l'ouverture.
    private(set) var credits: GuestCreditBalance = .none

    /// Intention de paiement choisie au récapitulatif, quand il y a quelque
    /// chose à régler. Aucune intégration bancaire n'est branchée : la valeur
    /// est seulement enregistrée avec la réservation.
    var paymentMode: PaymentMode = .carte
    /// Case « J'accepte les conditions d'annulation du club » du récapitulatif,
    /// cochée par défaut. Rien n'en est enregistré en base.
    var acceptsTerms = true

    // MARK: - Ouverture

    /// Réinitialise le brouillon pour un nouveau tunnel. Le réservataire est
    /// ajouté d'emblée : il est toujours le premier participant.
    ///
    /// - Parameters:
    ///   - court: terrain choisi.
    ///   - date: jour de la réservation.
    ///   - slot: créneau choisi.
    ///   - sport: sport du terrain ; fixe le format proposé par défaut.
    ///   - profile: personne au nom de qui l'on réserve (profil actif : soi ou
    ///     l'enfant sélectionné).
    func start(court: Court, date: Date, slot: TimeSlot, sport: Sport, profile: SessionProfile) {
        self.court = court
        self.date = date
        self.slot = slot
        self.sport = sport

        // Tout ce qui venait d'un tunnel précédent est remis à zéro.
        format = GameFormat.preferred(for: sport)
        participants = [.owner(profile)]
        credits = .none
        paymentMode = .carte
        acceptsTerms = true
    }

    /// Charge le solde de crédits. Séparé de `start` pour que l'écran s'affiche
    /// immédiatement, sans attendre le réseau.
    ///
    /// Le service lit la dotation (`guest_credit_allowances`, 2 par défaut) et
    /// compte les crédits déjà consommés sur la période d'adhésion ; sans
    /// adhésion active (cas d'un enfant sélectionné), le solde est nul.
    ///
    /// - Parameter profile: profil actif dont on cherche les crédits.
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
    /// participants excédentaires en partant de la fin, jamais le réservataire,
    /// qui est en tête de liste.
    ///
    /// - Parameter newFormat: format choisi.
    func setFormat(_ newFormat: GameFormat) {
        format = newFormat
        while participants.count > newFormat.capacity, participants.count > 1 {
            participants.removeLast()
        }
    }

    // MARK: - Participants

    /// Nombre de joueurs attendus par le format (2 ou 4).
    var capacity: Int { format.capacity }
    /// Joueurs encore à ajouter.
    var missingCount: Int { max(0, capacity - participants.count) }
    /// Vrai quand la liste est complète : condition pour continuer.
    var isComplete: Bool { missingCount == 0 }
    /// Vrai tant qu'on peut encore ajouter un joueur.
    var hasRoom: Bool { participants.count < capacity }

    /// Profils déjà dans la liste, pour les écarter des résultats de recherche.
    var takenProfileIds: Set<UUID> {
        Set(participants.compactMap(\.profileId))
    }

    /// Ajoute un adhérent trouvé par la recherche. Sans effet si la liste est
    /// pleine ou si ce membre y figure déjà.
    ///
    /// - Parameter member: résultat de `search_club_members` (ou partenaire
    ///   récent).
    func add(member: MemberSearchResult) {
        guard hasRoom, !takenProfileIds.contains(member.profileId) else { return }
        participants.append(.member(member))
    }

    /// Ajoute un invité non-membre. Sans effet si la liste est pleine.
    ///
    /// - Parameters:
    ///   - guestPrenom: prénom de l'invité.
    ///   - nom: nom de l'invité.
    ///   - payer: prise en charge de sa part (crédit ou supplément).
    func add(guestPrenom: String, nom: String, payer: GuestPayer) {
        guard hasRoom else { return }
        participants.append(.guest(prenom: guestPrenom, nom: nom, payer: payer))
    }

    /// Retirer un invité sur crédit rend ce crédit immédiatement : le solde
    /// affiché est dérivé de la liste, il n'y a aucun compteur à décrémenter.
    ///
    /// - Parameter participant: joueur à retirer ; le réservataire ne peut
    ///   pas l'être (sans effet).
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
    ///
    /// Code non utilisé à ce jour : `GuestFormSheet` fait sa propre
    /// présélection à partir des crédits restants.
    var preferredGuestPayer: GuestPayer {
        creditsRemaining > 0 ? .credit : .supplement
    }

    // MARK: - Montant

    /// Total à régler : la somme des suppléments. Les adhérents sont inclus
    /// dans leur cotisation, les invités sur crédit sont gratuits.
    /// En euros (10 € par invité au supplément).
    var total: Double {
        participants.reduce(0) { $0 + $1.supplement }
    }

    /// Vrai s'il y a quelque chose à régler : le récapitulatif affiche alors
    /// le choix du mode de paiement.
    var requiresPayment: Bool { total > 0 }

    /// Libellé du bouton final.
    /// « Payer 10,00 € » s'il y a un montant, « Confirmer la réservation »
    /// sinon.
    var confirmTitle: String {
        requiresPayment ? "Payer \(Price.amount(total))" : "Confirmer la réservation"
    }

    /// Confirmation possible : liste complète, conditions acceptées, terrain
    /// choisi.
    var canConfirm: Bool {
        isComplete && acceptsTerms && court != nil
    }
}
