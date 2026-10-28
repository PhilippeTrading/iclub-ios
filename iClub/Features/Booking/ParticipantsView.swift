//
//  ParticipantsView.swift
//  iClub
//
//  Étape 1 du tunnel : format de jeu et participants.
//
//  Le réservataire est toujours le premier participant, ajouté
//  automatiquement et non supprimable. On ne peut pas continuer tant que la
//  liste n'est pas complète — le bouton annonce ce qui manque.
//

import SwiftUI

/// Route vers le récapitulatif. Le brouillon porte l'état, la route ne sert
/// qu'à l'identité de la destination.
struct BookingSummaryRoute: Hashable {
    let courtId: UUID
    let slot: TimeSlot
}

struct ParticipantsView: View {
    let route: BookingSlotRoute
    let court: Court
    let draft: BookingDraft

    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var isSearchingMember = false
    @State private var isAddingGuest = false

    private var formats: [GameFormat] { GameFormat.options(for: route.sport) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                formatSection
                participantsSection
                creditsNote
                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Joueurs")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { continueBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        .sheet(isPresented: $isSearchingMember) {
            if let profile = auth.activeProfile {
                MemberSearchSheet(
                    clubId: court.clubId,
                    myProfileId: profile.id,
                    sport: route.sport,
                    excluded: draft.takenProfileIds,
                    onSelect: { draft.add(member: $0) }
                )
            }
        }
        .sheet(isPresented: $isAddingGuest) {
            GuestFormSheet(creditsRemaining: draft.creditsRemaining) { prenom, nom, payer in
                draft.add(guestPrenom: prenom, nom: nom, payer: payer)
            }
        }
        .task {
            guard let profile = auth.activeProfile else { return }
            await draft.loadCredits(profile: profile)
        }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.date.longFrenchDate)
                .metaLabelStyle()

            Text("\(court.nom) · \(route.slot.label)")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Format

    @ViewBuilder
    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .metaLabelStyle()

            if formats.count == 1, let only = formats.first {
                // Padel : l'information, pas un choix.
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(route.sport.accent)
                    Text("\(only.displayName) · \(only.detail)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    route.sport.accent.opacity(0.10),
                    in: .rect(cornerRadius: Radius.chip, style: .continuous)
                )
            } else {
                HStack(spacing: 8) {
                    ForEach(formats, id: \.self) { format in
                        formatChip(format)
                    }
                }
            }
        }
    }

    private func formatChip(_ format: GameFormat) -> some View {
        let isSelected = draft.format == format

        return Button {
            draft.setFormat(format)
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                Text(format.displayName)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(format.detail)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(isSelected ? Color.white : route.sport.accent)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? route.sport.accent : route.sport.accent.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Joueurs")
                    .metaLabelStyle()
                Spacer(minLength: 0)
                Text("\(draft.participants.count) / \(draft.capacity)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .monospacedDigit()
            }

            ForEach(draft.participants) { participant in
                participantRow(participant)
            }

            if draft.hasRoom {
                HStack(spacing: 8) {
                    addButton(title: "Adhérent", systemImage: "magnifyingglass") {
                        isSearchingMember = true
                    }
                    addButton(title: "Invité", systemImage: "person.badge.plus") {
                        isAddingGuest = true
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func participantRow(_ participant: BookingParticipant) -> some View {
        HStack(spacing: 12) {
            MemberAvatar(url: participant.avatarUrl, initials: participant.initials, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)

                Text(participant.roleLabel)
                    .font(.caption)
                    .foregroundStyle(roleTint(participant))
            }

            Spacer(minLength: 0)

            if participant.isRemovable {
                Button {
                    draft.remove(participant)
                    Haptics.tap()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.textSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retirer \(participant.displayName)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    private func roleTint(_ participant: BookingParticipant) -> Color {
        switch participant.kind {
        case .owner: Brand.navy700
        case .member: participant.hasActiveMembership ? Brand.textSecondary : Brand.warning
        case .guest: Brand.textSecondary
        }
    }

    private func addButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Brand.navy700)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .strokeBorder(Brand.navy700.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Crédits

    @ViewBuilder
    private var creditsNote: some View {
        if draft.credits.total > 0 {
            HStack(spacing: 10) {
                Image(systemName: "ticket")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.textSecondary)

                Text("\(draft.creditsRemaining) crédit\(draft.creditsRemaining > 1 ? "s" : "") invité sur \(draft.credits.total)")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Brand.textSecondary.opacity(0.08),
                in: .rect(cornerRadius: Radius.chip, style: .continuous)
            )
        } else if auth.activeProfile?.hasActiveMembership == false {
            InlineMessage(
                kind: .info,
                message: "Sans adhésion active, tu n'as pas de crédit invité : les invités règlent le supplément."
            )
        }
    }

    // MARK: - Continuer

    private var continueBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: continueTitle,
                systemImage: draft.isComplete ? "arrow.right" : nil
            ) {
                router.bookingPath.append(
                    BookingSummaryRoute(courtId: court.id, slot: route.slot)
                )
            }
            .disabled(!draft.isComplete)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var continueTitle: String {
        guard !draft.isComplete else { return "Continuer" }
        let missing = draft.missingCount
        return "Continuer — il manque \(missing) joueur\(missing > 1 ? "s" : "")"
    }
}
