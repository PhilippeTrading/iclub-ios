//
//  ReservationDetailView.swift
//  iClub
//
//  Détail d'une réservation : participants avec photo et classement, et
//  annulation réservée au créateur.
//
//  Les photos et classements passent par `get_club_roster_info` : la fiche d'un
//  autre membre n'est pas lisible directement. Le classement affiché dépend du
//  sport — tennis pour un tennis, padel pour un padel, rien en pickleball.
//

import SwiftUI

struct ReservationDetailView: View {
    let reservation: MyReservation
    let store: ReservationsStore

    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var roster: [UUID: RosterInfoRow] = [:]
    @State private var isLoadingRoster = true
    @State private var isConfirmingCancel = false
    @State private var isCancelling = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recapCard
                participantsSection

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

    private var statusTint: Color {
        if reservation.isCancelled { return Brand.error }
        return reservation.isPaid ? Brand.navy700 : Brand.success
    }

    // MARK: - Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Joueurs")
                .metaLabelStyle()

            ForEach(reservation.participants) { participant in
                participantRow(participant)
            }
        }
    }

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
                    SkeletonBlock(height: 10, cornerRadius: 5)
                        .frame(width: 90)
                }
            }

            Spacer(minLength: 0)

            if let createdBy = reservation.createdBy, participant.profileId == createdBy {
                BrandChip(title: "Réservataire", tint: Brand.navy700)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    // MARK: - Annulation

    @ViewBuilder
    private var cancelSection: some View {
        // Visible uniquement si j'ai créé la réservation : un simple
        // participant ne peut pas annuler la réservation d'un autre. Même règle
        // que dans la liste, sans test sur la date.
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

    private func loadRoster() async {
        let ids = reservation.participants.compactMap(\.profileId)
        guard !ids.isEmpty else {
            isLoadingRoster = false
            return
        }

        // Amorce avec ce que la liste a déjà chargé : les photos s'affichent
        // tout de suite, sans passer par les initiales le temps de l'appel.
        roster = store.roster

        roster = await ClubDirectoryService.rosterInfo(profileIds: ids)
        isLoadingRoster = false
    }

    private func cancel() {
        guard let profile = auth.sessionProfile else { return }
        isCancelling = true
        errorMessage = nil

        Task {
            do {
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
