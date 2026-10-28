//
//  BookingView.swift
//  iClub
//
//  Écran 1 du tunnel : choix de l'horaire.
//
//  Logique inversée par rapport à un planning classique — on choisit d'abord un
//  créneau, ensuite un terrain. Sur mobile une grille terrains × heures est
//  illisible : 17 terrains de tennis ne tiennent pas en largeur.
//
//  Seuls les créneaux ayant au moins un terrain libre sont listés. Un horaire
//  complet, ou déjà passé sur la journée en cours, n'apparaît pas.
//

import SwiftUI

/// Destination de navigation vers l'écran de choix du terrain.
struct BookingSlotRoute: Hashable {
    let sport: Sport
    let date: Date
    let slot: TimeSlot
}

struct BookingView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var availability = DayAvailabilityStore()

    /// Brouillon du tunnel. Porté par la racine : il survit aux pushes, et est
    /// réinitialisé à chaque nouvelle entrée depuis le choix du terrain.
    @State private var draft = BookingDraft()

    private var sports: [Sport] { catalog.availableSports }

    /// Sport affiché : celui retenu par le routeur (choisi ici ou via une tuile
    /// de l'accueil), sinon le premier sport proposé par le club.
    private var activeSport: Sport? {
        if let sport = router.bookingSport, sports.contains(sport) { return sport }
        return sports.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch catalog.state {
                case .idle, .loading:
                    loadingState

                case .failed(let message):
                    errorState(message) { await catalog.reload() }

                case .loaded where sports.isEmpty:
                    PhasePlaceholder(
                        systemImage: "figure.tennis",
                        title: "Aucun terrain ouvert",
                        message: "Le club n'a pas encore de terrain actif à la réservation."
                    )
                    .padding(.horizontal, -20)

                case .loaded:
                    sportPicker

                    if let activeSport {
                        surfaceBar(for: activeSport)
                        dayPicker(for: activeSport)
                        slotList(for: activeSport)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Réserver")
        // Les quatre étapes du tunnel sont déclarées ici, à la racine de la
        // pile : le brouillon et le magasin de disponibilités restent des
        // objets uniques, partagés par tous les écrans.
        .navigationDestination(for: BookingSlotRoute.self) { route in
            CourtPickerView(route: route, availability: availability, draft: draft)
        }
        .navigationDestination(for: BookingParticipantsRoute.self) { route in
            participantsDestination(route)
        }
        .navigationDestination(for: BookingSummaryRoute.self) { _ in
            BookingSummaryView(draft: draft)
        }
        .navigationDestination(for: BookingConfirmation.self) { confirmation in
            BookingConfirmedView(confirmation: confirmation)
        }
        // Recharge et réabonne à chaque changement de club ou de jour. Le sport
        // n'en fait pas partie : les réservations sont lues pour tout le club.
        .task(id: availabilityKey) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await availability.activate(clubId: clubId, date: selectedDay)
        }
        .refreshable {
            await catalog.reload()
            await availability.reload()
        }
        .animation(.smooth(duration: 0.3), value: activeSport)
    }

    /// Le terrain est relu dans le catalogue à l'affichage : s'il a été
    /// désactivé par l'admin pendant que l'utilisateur composait sa partie, on
    /// le dit plutôt que d'ouvrir un tunnel qui échouera à la confirmation.
    @ViewBuilder
    private func participantsDestination(_ route: BookingParticipantsRoute) -> some View {
        if let court = catalog.courts(for: route.slotRoute.sport)
            .first(where: { $0.id == route.courtId }) {
            ParticipantsView(route: route.slotRoute, court: court, draft: draft)
        } else {
            PhasePlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Terrain indisponible",
                message: "Ce terrain vient d'être retiré de la réservation. Choisis-en un autre.",
                accent: Brand.warning
            )
        }
    }

    // MARK: - Choix du sport

    private var sportPicker: some View {
        HStack(spacing: 8) {
            ForEach(sports) { sport in
                let isSelected = sport == activeSport
                Button {
                    router.bookingSport = sport
                    Haptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sport.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(sport.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(isSelected ? Color.white : sport.accent)
                    .background {
                        Capsule(style: .continuous)
                            .fill(isSelected ? sport.accent : sport.accent.opacity(0.12))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Filtre de surface

    @ViewBuilder
    private func surfaceBar(for sport: Sport) -> some View {
        let surfaces = catalog.surfaces(for: sport)

        // Une seule surface : le filtre n'aurait rien à filtrer.
        if surfaces.count > 1 {
            SurfaceFilterBar(
                surfaces: surfaces,
                accent: sport.accent,
                selection: surfaceBinding(for: sport)
            )
            .padding(.horizontal, -20)
        }
    }

    // MARK: - Choix du jour

    private func dayPicker(for sport: Sport) -> some View {
        DayStrip(
            days: days(for: sport),
            accent: sport.accent,
            selection: Binding(
                get: { selectedDay },
                set: { router.bookingDate = $0 }
            )
        )
        // La bande saigne jusqu'aux bords de l'écran, la marge de 20 pt étant
        // réappliquée à l'intérieur du `ScrollView`.
        .padding(.horizontal, -20)
    }

    // MARK: - Liste des créneaux

    @ViewBuilder
    private func slotList(for sport: Sport) -> some View {
        let surface = resolvedSurface(for: sport)
        let rows = openSlots(for: sport, surface: surface)

        if case .failed(let message) = availability.phase {
            errorState(message) { await availability.reload() }
        } else if rows.isEmpty, availability.phase != .ready {
            slotSkeletons
        } else if rows.isEmpty {
            emptySlotState(surface: surface)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(rows, id: \.slot) { row in
                    NavigationLink(value: BookingSlotRoute(sport: sport, date: selectedDay, slot: row.slot)) {
                        SlotRow(
                            slot: row.slot,
                            courts: row.courts,
                            accent: sport.accent,
                            priceLabel: Price.label(for: row.courts, hasActiveMembership: hidesPrices)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Créneaux ayant au moins un terrain libre après filtre de surface, avec
    /// la liste de ces terrains dans l'ordre `courts.ordre`.
    private func openSlots(for sport: Sport, surface: String?) -> [(slot: TimeSlot, courts: [Court])] {
        availability.slots(for: sport, catalog: catalog).compactMap { entry in
            let free = entry.availableCourts(surface: surface).map(\.court)
            return free.isEmpty ? nil : (entry.slot, free)
        }
    }

    // MARK: - Jour et surface retenus

    private func days(for sport: Sport) -> [Date] {
        DayStrip.days(horizonJours: catalog.settings(for: sport).horizonJours)
    }

    /// Le jour retenu doit toujours appartenir à l'horizon du sport affiché :
    /// un sport réservable 14 jours à l'avance puis un autre limité à 2 jours
    /// laisserait sinon une date hors plage sélectionnée.
    private var selectedDay: Date {
        let calendar = Calendar.current
        let candidates = activeSport.map(days(for:)) ?? []

        if let date = router.bookingDate,
           let match = candidates.first(where: { calendar.isDate($0, inSameDayAs: date) }) {
            return match
        }
        return candidates.first ?? calendar.startOfDay(for: .now)
    }

    /// Une surface disparue du catalogue (terrain désactivé par l'admin) revient
    /// silencieusement à « Tout » plutôt que de vider la liste sans explication.
    private func resolvedSurface(for sport: Sport) -> String? {
        guard let surface = router.bookingSurface,
              catalog.surfaces(for: sport).contains(surface)
        else { return nil }
        return surface
    }

    private func surfaceBinding(for sport: Sport) -> Binding<String?> {
        Binding(
            get: { resolvedSurface(for: sport) },
            set: { router.bookingSurface = $0 }
        )
    }

    /// Clé de rechargement : le club et le jour. Le sport est absent
    /// volontairement, les réservations étant lues pour l'ensemble du club.
    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: selectedDay))"
    }

    /// En l'absence de profil connu on masque les prix : afficher un tarif à un
    /// membre qui a une adhésion active serait une erreur plus visible que de
    /// n'afficher aucun prix.
    private var hidesPrices: Bool {
        auth.activeProfile?.hasActiveMembership ?? true
    }

    // MARK: - États

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(height: 38, cornerRadius: Radius.chip)
            SkeletonBlock(height: 78, cornerRadius: Radius.chip)
            slotSkeletons
        }
        .padding(.top, 8)
    }

    private var slotSkeletons: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonBlock(height: 62, cornerRadius: Radius.inner)
            }
        }
    }

    @ViewBuilder
    private func emptySlotState(surface: String?) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(surface == nil
                     ? "Aucun créneau disponible ce jour-là"
                     : "Aucun créneau disponible ce jour-là sur cette surface")
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)

                Text(surface == nil
                     ? "Essaie un autre jour dans la bande de dates."
                     : "Essaie un autre jour, ou repasse sur « Tout » pour voir toutes les surfaces.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                if surface != nil {
                    Button("Voir toutes les surfaces") {
                        router.bookingSurface = nil
                        Haptics.selection()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
            }
        }
    }

    private func errorState(_ message: String, retry: @escaping () async -> Void) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Planning indisponible")
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Button("Réessayer") {
                    Task { await retry() }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }
}

#Preview {
    NavigationStack { BookingView() }
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
}
