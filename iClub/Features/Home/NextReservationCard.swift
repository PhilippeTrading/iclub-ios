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

import SwiftUI

struct NextReservationCard: View {
    let reservation: MyReservation
    let roster: [UUID: RosterInfoRow]
    let onLeave: () -> Void

    /// Un simple participant d'une réservation classique n'a aucune action :
    /// il ne peut pas annuler la réservation d'un autre.
    private var canLeave: Bool {
        !reservation.isCancelled && (reservation.isOwner || reservation.isOpenGame)
    }

    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    dateBlock
                    details
                    Spacer(minLength: 0)
                }

                if canLeave {
                    Divider().opacity(0.4)
                    leaveButton
                }
            }
        }
    }

    // MARK: - Pavé date

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

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(reservation.courtName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)

                BrandChip(title: reservation.statusLabel, tint: statusTint)
                    .fixedSize()
            }

            Text(reservation.date.longFrenchDate)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

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
                .overlay { Circle().strokeBorder(Brand.surface, lineWidth: 1.5) }
            }
        }
    }

    private var playersLabel: String {
        let count = reservation.participants.count
        return count > 1 ? "\(count) joueurs" : "1 joueur"
    }

    // MARK: - Action

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

    private var accent: Color {
        reservation.sport?.accent ?? Brand.navy700
    }

    private var statusTint: Color {
        if reservation.isCancelled { return Brand.error }
        return reservation.isPaid ? Brand.navy700 : Brand.success
    }
}

#Preview {
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
