//
//  HomeView.swift
//  iClub
//
//  Premier écran après connexion.
//
//  Tout y est dérivé de la base : le compteur de terrains vient de `courts`,
//  l'heure de fermeture de `club_sport_settings`, la date de validité de
//  l'adhésion active, le solde de crédits d'un recalcul. Aucune valeur figée.
//

import SwiftUI

struct HomeView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var store = HomeStore()
    @State private var pendingLeave: MyReservation?
    @State private var isLeaving = false
    @State private var leaveError: String?

    private var profile: SessionProfile? { auth.sessionProfile }

    /// L'accueil ne met en avant que les deux sports principaux, et seulement
    /// s'ils ont un terrain actif : on ne propose jamais de réserver un sport
    /// sans terrain. Le pickleball reste accessible depuis l'onglet Réserver.
    private var shortcutSports: [Sport] {
        [.tennis, .padel].filter { catalog.courtCount(for: $0) > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                shortcuts
                nextReservationSection
                activitiesSection
                membershipSection
                creditsSection
                announcementsSection

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationDestination(for: MyReservation.self) { reservation in
            ReservationDetailView(reservation: reservation, store: ReservationsStore())
        }
        .task(id: profile?.id) {
            guard let profile else { return }
            await store.activate(profile: profile)
        }
        .refreshable {
            await auth.refreshSessionProfile()
            await catalog.reload()
            await store.reload()
        }
        .confirmationDialog(
            pendingLeave?.leaveConfirmationTitle ?? "",
            isPresented: leaveConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingLeave
        ) { reservation in
            Button(reservation.leaveActionTitle, role: .destructive) { leave(reservation) }
            Button("Conserver", role: .cancel) {}
        } message: { reservation in
            Text(reservation.leaveConfirmationMessage)
        }
        .alert("Action impossible", isPresented: leaveErrorBinding) {
            Button("OK") { leaveError = nil }
        } message: {
            Text(leaveError ?? "")
        }
        .overlay {
            if isLeaving {
                Color.black.opacity(0.08).ignoresSafeArea().overlay { ProgressView() }
            }
        }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bonjour \(profile?.greetingName ?? "")")
                .font(.editorial(.largeTitle))
                .foregroundStyle(Brand.navy800)
                .contentTransition(.opacity)

            Text(todayLine)
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            if let badge = membershipBadgeText {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                    Text(badge)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Brand.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brand.success.opacity(0.10), in: .capsule)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Jeudi 25 septembre · le club est ouvert jusqu'à 21 h ». La partie
    /// horaire disparaît si `club_sport_settings` n'a pas encore répondu.
    private var todayLine: String {
        let date = Date.now.longFrenchDate
        guard let minutes = catalog.latestClosingMinutes else { return date }
        return "\(date) · le club est ouvert jusqu'à \(closingLabel(minutes))"
    }

    private func closingLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        // « 21 h » se lit mieux que « 21 h 00 » dans une phrase.
        return remainder == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, remainder)
    }

    /// Rien si aucune adhésion active : ce n'est pas une erreur, juste un état.
    private var membershipBadgeText: String? {
        guard let profile, profile.hasActiveMembership else { return nil }
        guard let fin = profile.activeMembershipPeriod?.fin else { return "Adhésion à jour" }
        return "Valide jusqu'au \(fin.mediumFrenchDate)"
    }

    // MARK: - Raccourcis

    @ViewBuilder
    private var shortcuts: some View {
        switch catalog.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                SkeletonBlock(height: 132, cornerRadius: Radius.card)
                SkeletonBlock(height: 132, cornerRadius: Radius.card)
            }

        case .failed(let message):
            errorCard(title: "Terrains indisponibles", message: message) {
                await catalog.reload()
            }

        case .loaded where shortcutSports.isEmpty:
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aucun terrain disponible")
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Le club n'a pas encore ouvert de terrain à la réservation.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

        case .loaded:
            HStack(spacing: 12) {
                ForEach(shortcutSports) { sport in
                    SportShortcutTile(sport: sport, courtCount: catalog.courtCount(for: sport)) {
                        Haptics.tap()
                        router.openBooking(for: sport)
                    }
                }
            }
        }
    }

    // MARK: - Prochaine réservation

    @ViewBuilder
    private var nextReservationSection: some View {
        section("Votre prochaine réservation") {
            if let reservation = store.nextReservation {
                NavigationLink(value: reservation) {
                    NextReservationCard(
                        reservation: reservation,
                        roster: store.roster,
                        onLeave: { pendingLeave = reservation }
                    )
                }
                .buttonStyle(.plain)
            } else if store.phase != .ready {
                SkeletonBlock(height: 120, cornerRadius: Radius.card)
            } else {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Brand.textSecondary)
                            Text("Aucune réservation à venir.")
                                .font(.footnote)
                                .foregroundStyle(Brand.textSecondary)
                            Spacer(minLength: 0)
                        }

                        Button("Réserver un court") {
                            Haptics.tap()
                            router.selectedTab = .book
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                    }
                }
            }
        }
    }

    // MARK: - Cours

    @ViewBuilder
    private var activitiesSection: some View {
        // La carte disparaît entièrement s'il n'y a aucun cours, plutôt que
        // d'afficher une liste vide.
        if !store.activities.isEmpty {
            section("Cours et activités du club") {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.activities) { activity in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.name)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)

                                Text(activity.detailLine(courtName: courtName(activity.courtId)))
                                    .font(.caption)
                                    .foregroundStyle(Brand.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    // MARK: - Adhésion

    private var membershipSection: some View {
        section("Votre adhésion") {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    if let profile, profile.hasActiveMembership {
                        Text(membershipBadgeText ?? "Adhésion à jour")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)

                        if let details = profile.activeMembershipDetails {
                            Text("Formule \(details.formule) · \(Price.amount(details.montant))")
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                        }
                    } else {
                        // Jamais une date inventée, jamais un blanc.
                        Text("Aucune adhésion active pour l'instant.")
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Crédits invités

    private var creditsSection: some View {
        section("Vos crédits invités") {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(store.credits.available)")
                            .font(.numeral(.largeTitle))
                            .foregroundStyle(Brand.navy800)
                            .monospacedDigit()

                        Text("sur \(store.credits.total) restant\(store.credits.available > 1 ? "s" : "")")
                            .font(.subheadline)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    Text("Invitez gratuitement un joueur non membre — inclus dans votre cotisation.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Annonces

    @ViewBuilder
    private var announcementsSection: some View {
        if !store.announcements.isEmpty {
            section("Annonces récentes") {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.announcements) { announcement in
                            VStack(alignment: .leading, spacing: 4) {
                                BrandChip(
                                    title: announcement.level.displayName,
                                    tint: announcement.level.tint
                                )
                                .fixedSize()

                                Text(announcement.title)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)

                                if !announcement.body.isEmpty {
                                    Text(announcement.body)
                                        .font(.caption)
                                        .foregroundStyle(Brand.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Habillage commun

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .metaLabelStyle()
            content()
        }
    }

    private func errorCard(
        title: String,
        message: String,
        retry: @escaping () async -> Void
    ) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Button("Réessayer") { Task { await retry() } }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
            }
        }
    }

    // MARK: - Sortie de réservation

    private var leaveConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } })
    }

    private var leaveErrorBinding: Binding<Bool> {
        Binding(get: { leaveError != nil }, set: { if !$0 { leaveError = nil } })
    }

    private func leave(_ reservation: MyReservation) {
        guard let profile else { return }
        pendingLeave = nil
        isLeaving = true

        Task {
            do {
                if reservation.isOpenGame {
                    try await OpenGameService.leave(gameId: reservation.id)
                } else {
                    try await ReservationService.cancel(
                        reservationId: reservation.id,
                        by: profile.id
                    )
                }
                Haptics.destructive()
            } catch {
                leaveError = error.localizedDescription
                Haptics.failure()
            }
            await store.reload()
            isLeaving = false
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
}
