//
//  NextReservationCard.swift
//  iClub
//
//  « Votre prochaine réservation ».
//
//  Le bouton d'action applique **les mêmes règles que « Mes réservations »**,
//  via les libellés portés par `MyReservation` : annuler pour le créateur,
//  quitter pour un joueur de partie ouverte, rien pour un simple participant
//  d'une réservation classique. Aucune règle n'est réécrite ici.
//
//  Place dans l'application
//    Carte de la section « Votre prochaine réservation » de l'accueil
//    (`HomeView`). Toute la carte est un lien vers le détail de la réservation
//    (`ReservationDetailView`) ; le bouton du bas demande l'annulation ou la
//    sortie, que l'accueil confirme puis exécute.
//
//  Données
//    Aucune lecture ici : la réservation et les fiches des joueurs sont
//    fournies par `HomeStore`.
//
//  Règles, et ce que la base revérifie
//    - Annuler une réservation classique : seul son créateur le peut ; la base
//      l'impose aussi (politique RLS `reservations_update`, créateur ou
//      administrateur).
//    - Quitter une partie ouverte : tout joueur inscrit ; l'hôte qui la
//      quitte l'annule pour tous. La fonction SQL `leave_open_game` porte cette
//      règle.
//

import SwiftUI

/// Carte compacte de la prochaine réservation : pavé de date, terrain,
/// statut, horaire, joueurs, et bouton d'annulation ou de sortie.
struct NextReservationCard: View {
    /// Réservation à présenter (la plus proche à venir).
    let reservation: MyReservation
    /// Fiches des joueurs, indexées par profil, pour leurs photos.
    let roster: [UUID: RosterInfoRow]
    /// Appelé au tap sur le bouton d'annulation ou de sortie : l'accueil
    /// affiche alors sa demande de confirmation.
    let onLeave: () -> Void

    /// Un simple participant d'une réservation classique n'a aucune action :
    /// il ne peut pas annuler la réservation d'un autre.
    /// Une réservation déjà annulée n'en a pas non plus.
    private var canLeave: Bool {
        !reservation.isCancelled && (reservation.isOwner || reservation.isOpenGame)
    }

    /// Carte : date et détails côte à côte, puis le bouton d'action s'il y a
    /// lieu.
    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Ligne principale : pavé de date à gauche, détails à droite.
                HStack(alignment: .top, spacing: 12) {
                    dateBlock
                    details
                    Spacer(minLength: 0)
                }

                // Bouton d'action, seulement quand une action est permise.
                if canLeave {
                    Divider().opacity(0.4)
                    leaveButton
                }
            }
        }
    }

    // MARK: - Pavé date

    /// Jour de la semaine abrégé (« LUN. ») et numéro du jour, sur un fond
    /// teinté de la couleur du sport.
    private var dateBlock: some View {
        VStack(spacing: 1) {
            Text(reservation.date.frenchWeekdayAbbreviation)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(accent)

            Text(reservation.date.frenchDayNumber)
                .font(.numeral(.title2))
                .monospacedDigit()
                .foregroundStyle(Brand.textPrimary)
        }
        .frame(width: 52)
        .padding(.vertical, 8)
        .background(accent.opacity(0.10), in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }

    // MARK: - Détails

    /// Terrain et pastille de statut, date complète, horaire, puis photos et
    /// nombre de joueurs.
    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(reservation.courtName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)

                // « Confirmée », « Payé », « Partie complète » ou « Annulée ».
                BrandChip(title: reservation.statusLabel, tint: statusTint)
                    .fixedSize()
            }

            Text(reservation.date.longFrenchDate)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

            // Horaire du créneau, de l'heure de début à l'heure de fin
            // (`TimeSlot.label`).
            Text(reservation.slot.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.textPrimary)

            HStack(spacing: 8) {
                participantAvatars

                Text(playersLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }
            .padding(.top, 2)
        }
    }

    /// Photos des quatre premiers joueurs, qui se chevauchent légèrement.
    /// Un invité, ou un membre sans photo, apparaît avec ses initiales.
    private var participantAvatars: some View {
        HStack(spacing: -8) {
            ForEach(reservation.participants.prefix(4)) { participant in
                MemberAvatar(
                    url: participant.profileId
                        .flatMap { roster[$0]?.avatarUrl }
                        .flatMap(URL.init(string:)),
                    initials: participant.initials,
                    size: 22
                )
                // Liseré de la couleur de la carte, pour détacher les photos.
                .overlay { Circle().strokeBorder(Brand.surface, lineWidth: 1.5) }
            }
        }
    }

    /// « 1 joueur » ou « 4 joueurs », invités compris.
    private var playersLabel: String {
        let count = reservation.participants.count
        return count > 1 ? "\(count) joueurs" : "1 joueur"
    }

    // MARK: - Action

    /// Bouton rouge pâle « Annuler la réservation », « Annuler la partie » ou
    /// « Quitter la partie », selon `MyReservation.leaveActionTitle`.
    private var leaveButton: some View {
        Button { onLeave() } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                Text(reservation.leaveActionTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(Brand.error)
            .background(
                Brand.error.opacity(0.10),
                in: .rect(cornerRadius: Radius.chip, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Teintes

    /// Couleur du sport de la réservation, bleu marine si le sport est inconnu.
    private var accent: Color {
        reservation.sport?.accent ?? Brand.navy700
    }

    /// Teinte de la pastille de statut : rouge si annulée, bleu marine si
    /// payée, vert sinon.
    ///
    /// Attention : `MyReservation.isPaid` compare `statut_paiement` à « paye »,
    /// valeur que la base n'accepte plus depuis la migration 20261021170000
    /// (elle écrit « regle ») ; la teinte « payée » ne s'affiche donc plus.
    private var statusTint: Color {
        if reservation.isCancelled { return Brand.error }
        return reservation.isPaid ? Brand.navy700 : Brand.success
    }
}

/// Aperçu Xcode des trois cas d'action : hôte de partie ouverte, joueur de
/// partie ouverte, simple participant d'une réservation classique (sans
/// bouton).
#Preview {
    /// Fabrique une réservation fictive pour l'aperçu.
    func reservation(
        court: String,
        sport: Sport,
        openGame: Bool,
        owner: Bool,
        players: Int
    ) -> MyReservation {
        MyReservation(
            id: UUID(),
            date: Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now,
            slot: TimeSlot(startMinutes: 13 * 60 + 30, durationMinutes: 90),
            sport: sport,
            courtName: court,
            surface: "Terre battue",
            isIndoor: false,
            isCancelled: false,
            isPaid: false,
            isOwner: owner,
            createdBy: UUID(),
            isOpenGame: openGame,
            format: .double,
            participants: (0..<players).map { index in
                .init(profileId: UUID(), displayName: ["Marie Dupont", "Camille Roux", "Paul Bernard"][index % 3])
            }
        )
    }

    // Les trois cas d'action, dans l'ordre du tableau de règles.
    return ScrollView {
        VStack(spacing: 12) {
            NextReservationCard(
                reservation: reservation(court: "Padel 1", sport: .padel, openGame: true, owner: true, players: 2),
                roster: [:], onLeave: {}
            )
            NextReservationCard(
                reservation: reservation(court: "Central", sport: .tennis, openGame: true, owner: false, players: 3),
                roster: [:], onLeave: {}
            )
            NextReservationCard(
                reservation: reservation(court: "Tennis 3", sport: .tennis, openGame: false, owner: false, players: 2),
                roster: [:], onLeave: {}
            )
        }
        .padding(20)
    }
    .background(Brand.background)
}
