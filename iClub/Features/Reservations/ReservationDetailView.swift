//
//  ReservationDetailView.swift
//  iClub
//
//  Détail d'une réservation : participants avec photo et classement, et
//  annulation réservée au créateur.
//
//  Les photos et classements passent par `get_club_roster_info` : la fiche d'un
//  autre membre n'est pas lisible directement. Le classement affiché dépend du
//  sport : tennis pour un tennis, padel pour un padel, rien en pickleball.
//
//  Place dans l'application
//    Poussé par une carte de « Mes réservations » (`ReservationsView`, magasin
//    partagé) ou par la carte de prochaine réservation de l'accueil
//    (`HomeView`, qui fournit un magasin vide).
//
//  Données
//    La réservation est reçue telle quelle ; seules les fiches des joueurs
//    sont relues à l'affichage (`ClubDirectoryService.rosterInfo`).
//
//  Règles, et ce que la base revérifie
//    Le bouton « Annuler la réservation » n'apparaît que pour le créateur
//    d'une réservation non annulée, sans condition de date. L'annulation passe
//    la ligne `reservations` à `annulee` (`ReservationService.cancel`) ; la
//    RLS (`reservations_update`) ne l'autorise qu'au créateur ou à un
//    administrateur. Pour une partie ouverte dont on est l'hôte, cette même
//    annulation l'annule pour tous.
//
//  Points d'attention
//    Ouvert depuis l'accueil, le magasin fourni n'est pas chargé : après une
//    annulation, son `reload` ne fait rien et l'accueil se met à jour par son
//    propre temps réel.
//

import SwiftUI

/// Écran de détail d'une réservation.
struct ReservationDetailView: View {
    /// Réservation affichée, telle que lue par la liste ou l'accueil.
    let reservation: MyReservation
    /// Magasin de la liste : fiches déjà chargées (pour un affichage
    /// immédiat) et relecture après annulation.
    let store: ReservationsStore

    /// Session : compte connecté, auteur de l'annulation.
    @Environment(AuthController.self) private var auth
    /// Retour à l'écran précédent après annulation.
    @Environment(\.dismiss) private var dismiss

    /// Fiches des joueurs (photo, classements), indexées par profil.
    @State private var roster: [UUID: RosterInfoRow] = [:]
    /// Vrai jusqu'au retour de l'appel des fiches.
    @State private var isLoadingRoster = true
    /// Vrai pendant que la demande de confirmation est affichée.
    @State private var isConfirmingCancel = false
    /// Vrai pendant l'annulation.
    @State private var isCancelling = false
    /// Message d'échec de l'annulation, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?

    /// Récapitulatif, joueurs, erreur éventuelle et bouton d'annulation.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recapCard
                participantsSection

                // Échec de la dernière tentative d'annulation.
                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }

                cancelSection
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Réservation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRoster() }
        // Confirmation avant d'annuler.
        .confirmationDialog(
            "Annuler cette réservation ?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Annuler la réservation", role: .destructive) { cancel() }
            Button("Conserver", role: .cancel) {}
        } message: {
            Text("Le créneau redeviendra disponible pour les autres membres.")
        }
    }

    // MARK: - Récapitulatif

    /// Carte récapitulative : date et statut, horaire, terrain et sa
    /// description.
    private var recapCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(reservation.date.longFrenchDate)
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    BrandChip(title: reservation.statusLabel, tint: statusTint)
                }

                Text(reservation.slot.label)
                    .font(.editorial(.title2))
                    .foregroundStyle(Brand.navy800)

                Divider().opacity(0.4)

                // Terrain : pictogramme du sport (générique s'il est
                // inconnu), nom et « surface · intérieur ou extérieur ».
                HStack(spacing: 12) {
                    Image(systemName: reservation.sport?.symbolName ?? "sportscourt")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(reservation.sport?.accent ?? Brand.navy700)
                        .frame(width: 36, height: 36)
                        .background((reservation.sport?.accent ?? Brand.navy700).opacity(0.12), in: .circle)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(reservation.courtName)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text(reservation.courtDetail)
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Teinte de la pastille de statut : rouge si annulée, bleu marine si
    /// payée, vert sinon. Attention : « payée » repose sur
    /// `statut_paiement = 'paye'`, valeur que la base n'emploie plus (voir
    /// NextReservationCard.swift).
    private var statusTint: Color {
        if reservation.isCancelled { return Brand.error }
        return reservation.isPaid ? Brand.navy700 : Brand.success
    }

    // MARK: - Participants

    /// Section « Joueurs » : une carte par participant.
    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Joueurs")
                .metaLabelStyle()

            ForEach(reservation.participants) { participant in
                participantRow(participant)
            }
        }
    }

    /// Carte d'un participant : photo, nom, classement du sport (ou
    /// « Invité »), et pastille « Réservataire » pour le créateur.
    ///
    /// - Parameter participant: joueur affiché.
    /// - Returns: la carte.
    private func participantRow(_ participant: MyReservation.Participant) -> some View {
        let info = participant.profileId.flatMap { roster[$0] }
        let ranking = info?.ranking(for: reservation.sport)

        return HStack(spacing: 12) {
            MemberAvatar(
                url: info?.avatarUrl.flatMap(URL.init(string:)),
                initials: participant.initials,
                size: 40
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)

                // Un invité n'a ni fiche ni classement : on le dit plutôt que
                // de laisser une ligne vide.
                if participant.profileId == nil {
                    Text("Invité")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                } else if let ranking {
                    Text("Classement \(ranking)")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                } else if isLoadingRoster {
                    // Fiches pas encore arrivées : petite barre fantôme.
                    SkeletonBlock(height: 10, cornerRadius: 5)
                        .frame(width: 90)
                }
            }

            Spacer(minLength: 0)

            // Le créateur de la réservation, que ce soit moi ou non.
            if let createdBy = reservation.createdBy, participant.profileId == createdBy {
                BrandChip(title: "Réservataire", tint: Brand.navy700)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    // MARK: - Annulation

    /// Bouton rouge « Annuler la réservation », avec une roue pendant
    /// l'envoi.
    @ViewBuilder
    private var cancelSection: some View {
        // Visible uniquement si j'ai créé la réservation : un simple
        // participant ne peut pas annuler la réservation d'un autre. Même règle
        // que dans la liste, sans test sur la date.
        // (Un joueur non créateur d'une partie ouverte n'a pas de bouton ici :
        // il la quitte depuis la liste.)
        if reservation.isOwner, !reservation.isCancelled {
            Button(role: .destructive) {
                isConfirmingCancel = true
            } label: {
                HStack(spacing: 8) {
                    if isCancelling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text("Annuler la réservation")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(Brand.error)
            .disabled(isCancelling)
            .padding(.top, 4)
        }
    }

    // MARK: - Chargement

    /// Lit les fiches des joueurs inscrits (les invités n'en ont pas).
    private func loadRoster() async {
        let ids = reservation.participants.compactMap(\.profileId)
        guard !ids.isEmpty else {
            isLoadingRoster = false
            return
        }

        // Amorce avec ce que la liste a déjà chargé : les photos s'affichent
        // tout de suite, sans passer par les initiales le temps de l'appel.
        roster = store.roster

        // Puis les fiches à jour ; un échec rend un dictionnaire vide.
        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
        isLoadingRoster = false
    }

    /// Annule la réservation au nom du compte connecté, recharge la liste et
    /// revient en arrière ; en cas d'échec, affiche le message sous les
    /// joueurs.
    private func cancel() {
        guard let profile = auth.sessionProfile else { return }
        isCancelling = true
        errorMessage = nil

        Task {
            do {
                // Passe la ligne à `annulee` (date et auteur de l'annulation),
                // et retire le rappel local de la réservation.
                try await ReservationService.cancel(reservationId: reservation.id, by: profile.id)
                Haptics.destructive()
                // Le solde de crédits n'a rien à restituer explicitement : il
                // est recalculé, jamais stocké.
                await store.reload()
                isCancelling = false
                dismiss()
            } catch {
                isCancelling = false
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
    }
}
