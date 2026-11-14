//
//  MyReservation.swift
//  iClub
//
//  Réservations de l'utilisateur pour l'onglet « Réservations ».
//
//  Une réservation apparaît si je l'ai créée **ou** si j'y figure comme
//  participant : un membre ajouté par quelqu'un d'autre doit retrouver la
//  partie chez lui. Le bouton d'annulation, lui, ne dépend que de `created_by`.
//
//  Place dans l'application
//    Lu par `ReservationService.loadMine` (deux requêtes : mes participations,
//    puis les réservations), affiché par l'historique des réservations, le
//    détail d'une réservation, la carte « prochaine réservation » de l'accueil,
//    et utilisé pour programmer les rappels locaux (`BookingReminders`).
//
//  Droits et sécurité
//    Tout membre du club lit les réservations du club et leurs participants
//    (RLS `reservations_select_club`, `reservation_participants_select`) : le
//    filtre « les miennes » est fait par la requête, pas par la base.
//

import Foundation

// MARK: - DTO

/// Ligne de `reservations` avec son terrain et ses participants, tels que les
/// renvoie PostgREST grâce aux jointures déclarées dans `columns`.
nonisolated struct MyReservationRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `date` (`date`), en texte.
    let date: String?
    /// `heure_debut` (`time`), en texte.
    let heureDebut: String?
    /// `heure_fin` (`time`), en texte.
    let heureFin: String?
    /// `statut` : `confirmee` ou `annulee`.
    let statut: String?
    /// `statut_paiement` : `inclus`, `a_regler`, `regle` ou `rembourse` dans le
    /// schéma actuel.
    let statutPaiement: String?
    /// `created_by` : profil qui a créé la réservation.
    let createdBy: UUID?
    /// `format` : `simple` ou `double`.
    let format: String?
    /// `est_partie_ouverte` : la réservation est une partie ouverte.
    let estPartieOuverte: Bool?
    /// Terrain joint (`courts(…)`), `nil` si la jointure n'a rien rendu.
    let court: CourtBrief?
    /// Participants joints (`reservation_participants(…)`).
    let participants: [ParticipantBrief]

    /// Colonnes du terrain joint.
    nonisolated struct CourtBrief: Decodable, Sendable {
        /// `courts.nom`.
        let nom: String?
        /// `courts.surface`.
        let surface: String?
        /// `courts.couvert`.
        let couvert: Bool?
        /// `courts.sport`, valeur brute.
        let sport: String?
    }

    /// Colonnes d'un participant joint.
    nonisolated struct ParticipantBrief: Decodable, Sendable {
        /// `profile_id`, `nil` pour un invité.
        let profileId: UUID?
        /// `nom_affiche`.
        let nomAffiche: String?

        /// Correspondance avec les colonnes SQL.
        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case nomAffiche = "nom_affiche"
        }
    }

    /// Correspondance avec les colonnes SQL ; les jointures portent le nom de
    /// la table jointe (`courts`, `reservation_participants`).
    enum CodingKeys: String, CodingKey {
        case id, date, statut, format
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case statutPaiement = "statut_paiement"
        case createdBy = "created_by"
        case estPartieOuverte = "est_partie_ouverte"
        case court = "courts"
        case participants = "reservation_participants"
    }

    /// Sélection PostgREST avec jointures (clé étrangère `court_id` vers
    /// `courts`, et `reservation_participants.reservation_id`). `created_at` est
    /// demandée mais non décodée.
    static let columns = """
        id, date, heure_debut, heure_fin, statut, statut_paiement, created_by, created_at, \
        format, est_partie_ouverte, \
        courts(nom, surface, couvert, sport), reservation_participants(profile_id, nom_affiche)
        """

    /// Conversion vers le type du domaine.
    ///
    /// - Parameter myProfileId: profil du membre connecté, pour savoir s'il est
    ///   le créateur.
    /// - Returns: `nil` si la ligne n'a ni date ni heure exploitables : elle est
    ///   alors écartée plutôt qu'affichée à moitié.
    func toDomain(myProfileId: UUID) -> MyReservation? {
        guard let day = SupabaseDate.parse(date),
              let startMinutes = ClubSportSettingsRow.minutes(from: heureDebut)
        else { return nil }

        // La durée se déduit des deux bornes ; à défaut, on retombe sur une
        // heure plutôt que d'afficher un créneau de longueur nulle.
        let endMinutes = ClubSportSettingsRow.minutes(from: heureFin) ?? (startMinutes + 60)

        return MyReservation(
            id: id,
            date: day,
            slot: TimeSlot(startMinutes: startMinutes, durationMinutes: max(0, endMinutes - startMinutes)),
            sport: court?.sport.flatMap { Sport(rawValue: $0.lowercased()) },
            courtName: court?.nom ?? "Terrain",
            surface: court?.surface,
            isIndoor: court?.couvert ?? false,
            isCancelled: statut == ReservationInsert.cancelledStatus,
            // Attention : `paye` n'existe plus dans le schéma actuel (la
            // migration 20261021170000 l'a remplacé par `regle`, lignes
            // existantes comprises) : `isPaid` est donc toujours faux, et le
            // libellé « Payé » ne s'affiche plus.
            isPaid: statutPaiement == "paye",
            isOwner: createdBy == myProfileId,
            createdBy: createdBy,
            isOpenGame: estPartieOuverte == true,
            format: format.flatMap { GameFormat(rawValue: $0.lowercased()) },
            participants: participants.map {
                MyReservation.Participant(
                    profileId: $0.profileId,
                    displayName: $0.nomAffiche ?? "Participant"
                )
            }
        )
    }
}

/// Réservations où je figure comme joueur, première requête du couple.
nonisolated struct ParticipationRow: Decodable, Sendable {
    /// `reservation_participants.reservation_id`.
    let reservationId: UUID

    /// Correspondance avec la colonne SQL.
    enum CodingKeys: String, CodingKey {
        case reservationId = "reservation_id"
    }

    /// Colonne demandée.
    static let columns = "reservation_id"
}

// MARK: - Domaine

/// Une réservation du membre, prête à afficher.
nonisolated struct MyReservation: Identifiable, Hashable, Sendable {

    /// Un joueur de la réservation.
    nonisolated struct Participant: Identifiable, Hashable, Sendable {
        /// `nil` pour un invité non-membre : ni photo ni classement à afficher.
        let profileId: UUID?
        /// Nom affiché (`nom_affiche`), « Participant » à défaut.
        let displayName: String

        /// Identifiant de liste : le profil, ou le nom pour un invité (deux
        /// invités homonymes dans une même réservation partageraient le même).
        var id: String { profileId?.uuidString ?? displayName }

        /// Initiales des deux premiers mots du nom, « ? » à défaut.
        var initials: String {
            let parts = displayName.split(separator: " ").prefix(2)
            let value = parts.compactMap { $0.first.map(String.init) }.joined()
            return value.uppercased().isEmpty ? "?" : value.uppercased()
        }
    }

    /// `reservations.id`.
    let id: UUID
    /// Jour de la réservation, à minuit local.
    let date: Date
    /// Créneau (début et durée).
    let slot: TimeSlot
    /// Sport du terrain, `nil` s'il est inconnu de l'app.
    let sport: Sport?
    /// Nom du terrain, « Terrain » à défaut.
    let courtName: String
    /// Surface du terrain.
    let surface: String?
    /// Terrain couvert.
    let isIndoor: Bool
    /// Réservation annulée (`statut = 'annulee'`).
    let isCancelled: Bool
    /// `statut_paiement = 'paye'` (voir l'avertissement dans `toDomain`).
    let isPaid: Bool
    /// `true` seulement si j'ai créé la réservation : un simple participant ne
    /// peut pas annuler la réservation d'un autre.
    let isOwner: Bool
    /// Créateur de la réservation, pour marquer « Réservataire » dans la liste
    /// des joueurs même quand ce n'est pas moi.
    let createdBy: UUID?
    /// Une partie ouverte est une réservation comme les autres, distinguée par
    /// ce seul drapeau. Elle se quitte (`leave_open_game`) au lieu de s'annuler.
    let isOpenGame: Bool
    /// Nécessaire pour savoir si une partie ouverte est complète.
    let format: GameFormat?
    /// Joueurs inscrits.
    let participants: [Participant]

    /// Instant de début, pour trancher « à venir » / « passées ».
    /// (Jour à minuit local plus l'heure de début.)
    var startsAt: Date {
        Calendar.current.date(byAdding: .minute, value: slot.startMinutes, to: Calendar.current.startOfDay(for: date))
            ?? date
    }

    /// La réservation n'a pas encore commencé.
    var isUpcoming: Bool { startsAt >= .now }

    /// « Terre battue · Extérieur »
    var courtDetail: String {
        var parts: [String] = []
        if let surface, !surface.isEmpty { parts.append(surface) }
        parts.append(isIndoor ? "Intérieur" : "Extérieur")
        return parts.joined(separator: " · ")
    }

    /// Une partie ouverte complète n'apparaît plus dans « Parties ouvertes » :
    /// c'est ici qu'on le signale, et ici qu'on peut la quitter.
    var isFullOpenGame: Bool {
        guard isOpenGame, let format else { return false }
        return participants.count >= format.capacity
    }

    /// Statut affiché sur la ligne, par ordre de priorité : annulée, partie
    /// complète, payé, confirmée.
    var statusLabel: String {
        if isCancelled { return "Annulée" }
        if isFullOpenGame { return "Partie complète" }
        return isPaid ? "Payé" : "Confirmée"
    }

    /// Libellé de l'action de sortie. L'hôte annule la partie entière ; un
    /// participant ne libère que sa place, et la partie réapparaît dans la liste.
    var leaveActionTitle: String {
        guard isOpenGame else { return "Annuler la réservation" }
        return isOwner ? "Annuler la partie" : "Quitter la partie"
    }

    /// Titre de la fenêtre de confirmation de sortie.
    var leaveConfirmationTitle: String {
        guard isOpenGame else { return "Annuler cette réservation ?" }
        return isOwner ? "Annuler cette partie ?" : "Quitter cette partie ?"
    }

    /// Message de la fenêtre de confirmation de sortie : ce qui va se passer
    /// pour les autres joueurs.
    var leaveConfirmationMessage: String {
        if !isOpenGame {
            return "Le créneau redeviendra disponible pour les autres membres."
        }
        return isOwner
            ? "La partie sera annulée pour tous les joueurs et le créneau rendu au club. Il n'y a pas de transfert d'hôte."
            : "Ta place sera libérée et la partie réapparaîtra dans Parties ouvertes."
    }
}
