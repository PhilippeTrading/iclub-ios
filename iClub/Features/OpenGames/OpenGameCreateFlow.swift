//
//  OpenGameCreateFlow.swift
//  iClub
//
//  Tunnel d'ouverture d'une partie : sport → créneau → terrain → réglages.
//
//  Le choix du créneau réutilise les composants du planning classique
//  (`DayAvailabilityStore`, `DayStrip`, `SurfaceFilterBar`, `SlotRow`) : une
//  partie ouverte étant une réservation, il n'y a aucune raison d'avoir deux
//  moteurs de disponibilité qui pourraient divergerentre eux.
//
//  Un bandeau rappelle en permanence que le créneau choisi sera réservé au nom
//  du membre — il bloque le terrain dès la création, avant que quiconque ait
//  rejoint.
//

import SwiftUI

// MARK: - Routes

struct OpenGameSportRoute: Hashable {}

/// Détail d'une partie, ouvert depuis une notification.
struct OpenGameDetailRoute: Hashable {
    let gameId: UUID
}

struct OpenGameSlotRoute: Hashable {
    let sport: Sport
}

struct OpenGameFormRoute: Hashable {
    let sport: Sport
    let date: Date
    let slot: TimeSlot
    let courtId: UUID
}

// MARK: - Choix du sport

struct OpenGameSportPickerView: View {
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    private var sports: [Sport] { catalog.availableSports }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banner

                Text("Pour quel sport ?")
                    .metaLabelStyle()

                ForEach(sports) { sport in
                    Button {
                        Haptics.tap()
                        router.openGamesPath.append(OpenGameSlotRoute(sport: sport))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: sport.symbolName)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(sport.accent)
                                .frame(width: 42, height: 42)
                                .background(sport.accent.opacity(0.12), in: .circle)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(sport.displayName)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)
                                Text(courtCountLabel(sport))
                                    .font(.caption)
                                    .foregroundStyle(Brand.textSecondary)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.textSecondary.opacity(0.6))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surfaceCard(cornerRadius: Radius.inner)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Ouvrir une partie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func courtCountLabel(_ sport: Sport) -> String {
        let count = catalog.courtCount(for: sport)
        return count > 1 ? "\(count) terrains" : "\(count) terrain"
    }

    private var banner: some View {
        OpenGameModeBanner()
    }
}

/// Bandeau rappelant l'effet de l'ouverture d'une partie.
struct OpenGameModeBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.pine800)

            Text("Le créneau choisi sera réservé à ton nom, puis proposé aux autres membres.")
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Brand.pine50,
            in: .rect(cornerRadius: Radius.chip, style: .continuous)
        )
    }
}

// MARK: - Choix du créneau

struct OpenGameSlotPickerView: View {
    let sport: Sport

    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var availability = DayAvailabilityStore()
    @State private var selectedDay: Date?
    @State private var surface: String?

    private var days: [Date] {
        DayStrip.days(horizonJours: catalog.settings(for: sport).horizonJours)
    }

    private var day: Date {
        let calendar = Calendar.current
        if let selectedDay,
           let match = days.first(where: { calendar.isDate($0, inSameDayAs: selectedDay) }) {
            return match
        }
        return days.first ?? calendar.startOfDay(for: .now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OpenGameModeBanner()
                    .padding(.horizontal, 20)

                surfaceBar
                dayStrip
                slotList

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(sport.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: availabilityKey) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await availability.activate(clubId: clubId, date: day)
        }
        .refreshable {
            await catalog.reload()
            await availability.reload()
        }
    }

    @ViewBuilder
    private var surfaceBar: some View {
        let surfaces = catalog.surfaces(for: sport)
        if surfaces.count > 1 {
            SurfaceFilterBar(surfaces: surfaces, accent: sport.accent, selection: $surface)
        }
    }

    private var dayStrip: some View {
        DayStrip(
            days: days,
            accent: sport.accent,
            selection: Binding(get: { day }, set: { selectedDay = $0 })
        )
    }

    @ViewBuilder
    private var slotList: some View {
        let rows = openSlots

        if case .failed(let message) = availability.phase {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Planning indisponible")
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                    Button("Réessayer") { Task { await availability.reload() } }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                }
            }
            .padding(.horizontal, 20)
        } else if rows.isEmpty, availability.phase != .ready {
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonBlock(height: 62, cornerRadius: Radius.inner)
                }
            }
            .padding(.horizontal, 20)
        } else if rows.isEmpty {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aucun créneau libre ce jour-là")
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Essaie un autre jour dans la bande de dates.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(.horizontal, 20)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(rows, id: \.slot) { row in
                    NavigationLink(value: OpenGameCourtRoute(
                        sport: sport, date: day, slot: row.slot
                    )) {
                        SlotRow(
                            slot: row.slot,
                            courts: row.courts,
                            accent: sport.accent,
                            // Une partie ouverte ne fait pas payer l'hôte :
                            // aucun tarif n'a de sens ici.
                            priceLabel: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var openSlots: [(slot: TimeSlot, courts: [Court])] {
        availability.slots(for: sport, catalog: catalog).compactMap { entry in
            let free = entry.availableCourts(surface: resolvedSurface).map(\.court)
            return free.isEmpty ? nil : (entry.slot, free)
        }
    }

    private var resolvedSurface: String? {
        guard let surface, catalog.surfaces(for: sport).contains(surface) else { return nil }
        return surface
    }

    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: day))"
    }
}

// MARK: - Choix du terrain

struct OpenGameCourtRoute: Hashable {
    let sport: Sport
    let date: Date
    let slot: TimeSlot
}

struct OpenGameCourtPickerView: View {
    let route: OpenGameCourtRoute

    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var availability = DayAvailabilityStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OpenGameModeBanner()

                VStack(alignment: .leading, spacing: 4) {
                    Text(route.date.longFrenchDate)
                        .metaLabelStyle()
                    Text(route.slot.label)
                        .font(.editorial(.title2))
                        .foregroundStyle(Brand.navy800)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                courtList
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(route.slot.startLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: availabilityKey) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await availability.activate(clubId: clubId, date: route.date)
        }
        .refreshable { await availability.reload() }
    }

    @ViewBuilder
    private var courtList: some View {
        let states = availability
            .slots(for: route.sport, catalog: catalog)
            .first { $0.slot == route.slot }?
            .courts ?? []

        LazyVStack(spacing: 8) {
            ForEach(states) { state in
                let court = state.court
                Button {
                    guard state.isAvailable else { return }
                    Haptics.tap()
                    router.openGamesPath.append(OpenGameFormRoute(
                        sport: route.sport,
                        date: route.date,
                        slot: route.slot,
                        courtId: court.id
                    ))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: route.sport.symbolName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(state.isAvailable ? route.sport.accent : Brand.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(
                                (state.isAvailable ? route.sport.accent : Brand.textSecondary).opacity(0.12),
                                in: .circle
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(court.nom)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(state.isAvailable ? Brand.textPrimary : Brand.textSecondary)
                            Text(court.descriptionLabel)
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if let reason = state.availability.reason {
                            BrandChip(title: reason, tint: Brand.textSecondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: Radius.inner)
                    .opacity(state.isAvailable ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .disabled(!state.isAvailable)
            }
        }
    }

    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: route.date))"
    }
}
