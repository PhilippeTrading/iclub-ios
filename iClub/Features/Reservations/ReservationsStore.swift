//
//  ReservationsStore.swift
//  iClub
//
//  Réservations de l'utilisateur : celles qu'il a créées **et** celles où il
//  figure comme participant. Un membre ajouté par quelqu'un d'autre doit
//  retrouver la partie chez lui.
//
//  Place dans l'application
//    Magasin de l'écran « Réservations » (`ReservationsView`), partagé avec
//    le détail d'une réservation (`ReservationDetailView`). L'accueil crée
//    aussi une instance vide pour ouvrir le détail ; elle n'est jamais chargée
//    (son `reload` ne fait alors rien).
//
//  Sources
//    `ReservationService.loadMine` : réservations du club (table
//    `reservations`, avec terrain et participants) créées par le profil ou
//    auxquelles il participe (`reservation_participants`), annulées comprises,
//    passées comprises. Puis la fonction SQL `get_club_roster_info` pour les
//    photos et classements. La RLS ouvre ces lectures à tout membre du club.
//
//  Fil d'exécution et erreurs
//    Classe sur l'acteur principal (réglage par défaut du projet). Une erreur
//    n'efface jamais une liste déjà affichée.
//
//  Points d'attention
//    Limite connue : toutes les réservations du profil sont relues à chaque
//    chargement, sans pagination ni borne de date ; au-delà de la limite de
//    lignes par appel de l'API Supabase (mille par défaut), les plus récentes
//    ne seraient plus lues (tri par date croissante).
//

import Foundation
import Observation

/// Magasin des réservations d'un profil (soi, ou l'enfant sélectionné).
@Observable
final class ReservationsStore {

    /// Avancement du chargement.
    enum Phase: Equatable {
        /// Rien n'a encore été demandé.
        case idle
        /// Premier chargement en cours.
        case loading
        /// Liste disponible (éventuellement vide).
        case ready
        /// Lecture impossible alors qu'aucune réservation n'était affichée.
        case failed(String)
    }

    /// Avancement, observé par l'écran.
    private(set) var phase: Phase = .idle
    /// Toutes les réservations du profil, dans l'ordre renvoyé par la base
    /// (date puis heure croissantes).
    private(set) var reservations: [MyReservation] = []

    /// Photos et classements des participants, indexés par profil.
    ///
    /// `reservation_participants` ne porte que `nom_affiche` : la photo d'un
    /// autre membre passe obligatoirement par `get_club_roster_info`, les
    /// règles de sécurité interdisant de lire sa fiche directement.
    private(set) var roster: [UUID: RosterInfoRow] = [:]

    /// Club du dernier chargement, pour `reload`.
    private var clubId: UUID?
    /// Profil du dernier chargement, pour `reload`.
    private var profileId: UUID?

    /// À venir, de la plus proche à la plus lointaine.
    /// « À venir » : heure de début non encore atteinte (fuseau de
    /// l'appareil), annulées comprises.
    var upcoming: [MyReservation] {
        reservations
            .filter(\.isUpcoming)
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// Passées, de la plus récente à la plus ancienne : c'est l'ordre utile.
    var past: [MyReservation] {
        reservations
            .filter { !$0.isUpcoming }
            .sorted { $0.startsAt > $1.startsAt }
    }

    /// Charge les réservations d'un profil, puis les fiches de leurs joueurs.
    ///
    /// - Parameters:
    ///   - clubId: club du profil.
    ///   - profileId: profil dont on lit les réservations (créateur ou
    ///     participant).
    func load(clubId: UUID, profileId: UUID) async {
        self.clubId = clubId
        self.profileId = profileId

        // Squelettes seulement quand rien n'est affiché.
        if reservations.isEmpty { phase = .loading }

        do {
            reservations = try await ReservationService.loadMine(clubId: clubId, profileId: profileId)
            phase = .ready
            await loadRoster()
        } catch {
            // On garde la liste déjà chargée : une coupure réseau ne doit pas
            // vider l'écran.
            phase = reservations.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }

    /// Recharge le dernier profil chargé ; sans effet si `load` n'a jamais été
    /// appelé.
    func reload() async {
        guard let clubId, let profileId else { return }
        await load(clubId: clubId, profileId: profileId)
    }

    /// Un seul appel pour tous les participants de toutes les réservations.
    /// Tolérant à l'échec : sans lui les vignettes gardent leurs initiales.
    ///
    /// Les invités n'ont pas de `profile_id` et sont donc absents du résultat :
    /// ils conservent leurs initiales, ce qui est correct, puisqu'ils n'ont pas
    /// de fiche au club.
    private func loadRoster() async {
        // Identifiants distincts des membres inscrits.
        let ids = Array(Set(reservations.flatMap { $0.participants.compactMap(\.profileId) }))
        guard !ids.isEmpty else {
            roster = [:]
            return
        }
        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
    }
}
