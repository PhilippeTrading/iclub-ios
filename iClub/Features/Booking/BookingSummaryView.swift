//
//  BookingSummaryView.swift
//  iClub
//
//  Étape 2 du tunnel : récapitulatif, détail du montant, paiement.
//
//  Le bloc de paiement n'apparaît que si le total est supérieur à zéro : une
//  partie entre adhérents à jour ne déclenche aucun paiement, et le bouton
//  final dit simplement « Confirmer la réservation ».
//
//  Aucune intégration bancaire n'est branchée — les trois modes sont des
//  intentions enregistrées en base, que le club traite ensuite.
//

import SwiftUI

struct BookingSummaryView: View {
    let draft: BookingDraft

    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var isConfirming = false
    @State private var errorMessage: String?
    /// Vrai quand l'échec est un créneau pris entre-temps : on renvoie alors
    /// l'utilisateur vers la liste rafraîchie plutôt que de le laisser sur place.
    @State private var slotWasTaken = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recapCard
                participantsCard
                amountCard

                if draft.requiresPayment {
                    paymentSection
                }

                termsToggle

                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Récapitulatif")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { confirmBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        .alert("Créneau indisponible", isPresented: $slotWasTaken) {
            Button("Choisir un autre créneau") {
                // Retour à la racine du tunnel : la liste des créneaux est
                // abonnée au temps réel, elle est déjà à jour.
                router.bookingPath = NavigationPath()
            }
        } message: {
            Text(ReservationError.slotAlreadyTaken.localizedDescription)
        }
    }

    // MARK: - Récapitulatif

    @ViewBuilder
    private var recapCard: some View {
        if let court = draft.court {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(draft.date.longFrenchDate)
                        .metaLabelStyle()

                    Text(draft.slot.label)
                        .font(.editorial(.title2))
                        .foregroundStyle(Brand.navy800)

                    Divider().opacity(0.4)

                    HStack(spacing: 12) {
                        Image(systemName: draft.sport.symbolName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(draft.sport.accent)
                            .frame(width: 36, height: 36)
                            .background(draft.sport.accent.opacity(0.12), in: .circle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(court.nom)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(court.descriptionLabel)
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                        }

                        Spacer(minLength: 0)

                        BrandChip(
                            title: "\(draft.format.displayName) · \(draft.capacity)",
                            tint: draft.sport.accent
                        )
                    }
                }
            }
        }
    }

    // MARK: - Participants

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Joueurs")
                .metaLabelStyle()

            ForEach(draft.participants) { participant in
                HStack(spacing: 12) {
                    MemberAvatar(url: participant.avatarUrl, initials: participant.initials, size: 34)

                    Text(participant.displayName)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)

                    Spacer(minLength: 0)

                    Text(participant.roleLabel)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard(cornerRadius: Radius.chip)
            }
        }
    }

    // MARK: - Détail du montant

    private var amountCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Montant")
                    .metaLabelStyle()

                ForEach(draft.participants) { participant in
                    amountRow(participant)
                }

                Divider().opacity(0.4)

                HStack {
                    Text("Total à régler")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                    Text(Price.amount(draft.total))
                        .font(.numeral(.title3))
                        .foregroundStyle(draft.requiresPayment ? Brand.navy800 : Brand.success)
                }
            }
        }
    }

    private func amountRow(_ participant: BookingParticipant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(participant.displayName)
                    .font(.footnote)
                    .foregroundStyle(Brand.textPrimary)

                if participant.usesCredit {
                    Text("Crédit invité utilisé (\(participant.displayName))")
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Spacer(minLength: 0)

            Text(amountLabel(participant))
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(participant.supplement > 0 ? Brand.textPrimary : Brand.success)
                .fixedSize()
        }
    }

    private func amountLabel(_ participant: BookingParticipant) -> String {
        if participant.supplement > 0 { return Price.amount(participant.supplement) }
        if participant.usesCredit { return "Gratuit" }
        return "Inclus"
    }

    // MARK: - Paiement

    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paiement")
                .metaLabelStyle()

            ForEach(PaymentMode.allCases) { mode in
                paymentOption(mode)
            }
        }
    }

    private func paymentOption(_ mode: PaymentMode) -> some View {
        let isSelected = draft.paymentMode == mode

        return Button {
            draft.paymentMode = mode
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.navy700)
                    .frame(width: 26)

                Text(mode.displayName)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Brand.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? Brand.navy700 : Brand.hairline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: Radius.inner)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Conditions

    private var termsToggle: some View {
        @Bindable var draft = draft

        return Toggle(isOn: $draft.acceptsTerms) {
            Text("J'accepte les conditions d'annulation du club.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
        }
        .toggleStyle(.switch)
        .tint(Brand.navy700)
        .padding(14)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    // MARK: - Confirmation

    private var confirmBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: draft.confirmTitle,
                systemImage: draft.requiresPayment ? "creditcard" : "checkmark",
                isLoading: isConfirming
            ) {
                confirm()
            }
            .disabled(!draft.canConfirm || isConfirming)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private func confirm() {
        guard let profile = auth.sessionProfile, let court = draft.court else { return }
        isConfirming = true
        errorMessage = nil

        Task {
            do {
                let reservationId = try await ReservationService.confirm(
                    clubId: profile.clubId,
                    court: court,
                    date: draft.date,
                    slot: draft.slot,
                    format: draft.format,
                    participants: draft.participants,
                    total: draft.total,
                    paymentMode: draft.requiresPayment ? draft.paymentMode : nil,
                    createdBy: profile.id
                )

                Haptics.success()
                isConfirming = false

                // Le tunnel se referme derrière l'écran de succès : le geste
                // arrière ne doit pas ramener sur un récapitulatif dont la
                // réservation est déjà enregistrée.
                var path = NavigationPath()
                path.append(
                    BookingConfirmation(
                        reservationId: reservationId,
                        courtName: court.nom,
                        clubName: profile.clubName,
                        date: draft.date,
                        slot: draft.slot,
                        playerCount: draft.participants.count,
                        isPaid: draft.requiresPayment,
                        participantNames: draft.participants.map(\.displayName)
                    )
                )
                router.bookingPath = path

            } catch ReservationError.slotAlreadyTaken {
                isConfirming = false
                Haptics.failure()
                slotWasTaken = true
            } catch {
                isConfirming = false
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
        }
    }
}
