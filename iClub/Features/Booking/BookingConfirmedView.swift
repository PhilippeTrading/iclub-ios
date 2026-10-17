//
//  BookingConfirmedView.swift
//  iClub
//
//  Écran de succès, et non un simple retour en arrière : la confirmation est
//  un aboutissement, elle mérite son écran.
//
//  La route porte toutes ses données : elle reste affichable même si le
//  brouillon du tunnel est réinitialisé derrière elle.
//

import SwiftUI

/// Destination de l'écran de succès. `Hashable` et autoportante.
struct BookingConfirmation: Hashable {
    let reservationId: UUID
    let courtName: String
    let clubName: String
    let date: Date
    let slot: TimeSlot
    let playerCount: Int
    let isPaid: Bool
    let participantNames: [String]

    /// Bornes réelles de l'événement calendrier.
    var startsAt: Date {
        let calendar = Calendar.current
        return calendar.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: calendar.startOfDay(for: date)
        ) ?? date
    }

    var endsAt: Date {
        startsAt.addingTimeInterval(TimeInterval(slot.durationMinutes * 60))
    }

    /// « Central — Tennis Club de la Plaine »
    var eventTitle: String { "\(courtName) — \(clubName)" }

    var shareText: String {
        """
        Réservation confirmée !
        \(courtName) · \(clubName)
        \(date.longFrenchDate)
        \(slot.label)
        Joueurs : \(participantNames.joined(separator: ", "))
        """
    }
}

struct BookingConfirmedView: View {
    let confirmation: BookingConfirmation

    @Environment(AppRouter.self) private var router

    @State private var calendarMessage: String?
    @State private var calendarDidSucceed = false
    @State private var isAddingToCalendar = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                successMark
                recapCard
                actions

                if let calendarMessage {
                    InlineMessage(
                        kind: calendarDidSucceed ? .success : .error,
                        message: calendarMessage
                    )
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("")
        // Le tunnel est déjà refermé : on masque aussi le bouton retour pour
        // qu'aucun geste ne ramène dans un récapitulatif périmé.
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) { homeBar }
    }

    // MARK: - Coche

    private var successMark: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(Brand.success)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text("Votre réservation est confirmée")
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Récapitulatif

    private var recapCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(confirmation.date.longFrenchDate)
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    BrandChip(
                        title: confirmation.isPaid ? "Payé" : "Confirmée",
                        systemImage: "checkmark.seal.fill",
                        tint: Brand.success
                    )
                }

                Text(confirmation.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                Divider().opacity(0.4)

                detailRow(systemImage: "sportscourt", text: confirmation.courtName)
                detailRow(systemImage: "building.2", text: confirmation.clubName)
                detailRow(
                    systemImage: "person.2",
                    text: "\(confirmation.playerCount) joueur\(confirmation.playerCount > 1 ? "s" : "")"
                )
            }
        }
    }

    private func detailRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.textPrimary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            SecondaryActionButton(
                title: isAddingToCalendar ? "Ajout en cours…" : "Ajouter à mon calendrier",
                systemImage: "calendar.badge.plus"
            ) {
                addToCalendar()
            }
            .disabled(isAddingToCalendar || calendarDidSucceed)

            ShareLink(item: confirmation.shareText) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Partager aux participants")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func addToCalendar() {
        isAddingToCalendar = true
        calendarMessage = nil

        Task {
            do {
                try await CalendarExport.addEvent(
                    title: confirmation.eventTitle,
                    start: confirmation.startsAt,
                    end: confirmation.endsAt,
                    notes: "Joueurs : \(confirmation.participantNames.joined(separator: ", "))"
                )
                calendarDidSucceed = true
                calendarMessage = "Ajouté à ton calendrier."
                Haptics.success()
            } catch {
                calendarDidSucceed = false
                calendarMessage = error.localizedDescription
                Haptics.warning()
            }
            isAddingToCalendar = false
        }
    }

    // MARK: - Retour

    private var homeBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(title: "Retour à l'accueil", systemImage: "house") {
                router.closeBookingFlow()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}

#Preview {
    NavigationStack {
        BookingConfirmedView(
            confirmation: BookingConfirmation(
                reservationId: UUID(),
                courtName: "Central",
                clubName: "Tennis Club de la Plaine",
                date: .now,
                slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 60),
                playerCount: 4,
                isPaid: true,
                participantNames: ["Marie Dupont", "Camille Roux", "Léa Martin", "Paul Bernard"]
            )
        )
    }
    .environment(AppRouter())
}
