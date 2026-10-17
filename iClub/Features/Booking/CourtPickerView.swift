//
//  CourtPickerView.swift
//  iClub
//
//  Écran 2 du tunnel : choix du terrain, l'horaire étant déjà fixé.
//
//  Contrairement à l'écran 1, *tous* les terrains du sport sont affichés — y
//  compris ceux qui ne sont pas libres, grisés et accompagnés de leur raison.
//  Masquer les terrains occupés donnerait une liste qui change de longueur d'un
//  créneau à l'autre, sans qu'on comprenne pourquoi.
//
//  Le filtre de surface reste actif ici : on peut élargir à « Tout » sans
//  revenir en arrière.
//

import SwiftUI

/// Destination de l'écran des participants. Le terrain est repassé par son
/// identifiant plutôt que par valeur : il est relu dans le catalogue, et donc
/// toujours à jour si l'admin l'a modifié entre-temps.
struct BookingParticipantsRoute: Hashable {
    let slotRoute: BookingSlotRoute
    let courtId: UUID
}

struct CourtPickerView: View {
    let route: BookingSlotRoute
    let availability: DayAvailabilityStore
    let draft: BookingDraft

    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                surfaceBar
                courtList
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(route.slot.startLabel)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await availability.reload() }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.date.longFrenchDate)
                .metaLabelStyle()

            Text(route.slot.label)
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filtre de surface

    @ViewBuilder
    private var surfaceBar: some View {
        let surfaces = catalog.surfaces(for: route.sport)

        if surfaces.count > 1 {
            SurfaceFilterBar(
                surfaces: surfaces,
                accent: route.sport.accent,
                selection: Binding(
                    get: { resolvedSurface },
                    set: { router.bookingSurface = $0 }
                )
            )
            .padding(.horizontal, -20)
        }
    }

    // MARK: - Terrains

    @ViewBuilder
    private var courtList: some View {
        let states = courtStates

        if states.isEmpty {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aucun terrain sur cette surface")
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Repasse sur « Tout » pour voir l'ensemble des terrains.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(states) { state in
                    courtRow(state)
                }
            }
        }
    }

    private func courtRow(_ state: CourtSlotState) -> some View {
        let court = state.court
        let isAvailable = state.isAvailable

        return Button {
            select(court)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: route.sport.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isAvailable ? route.sport.accent : Brand.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(
                        (isAvailable ? route.sport.accent : Brand.textSecondary).opacity(0.12),
                        in: .circle
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(court.nom)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(isAvailable ? Brand.textPrimary : Brand.textSecondary)

                    Text(court.descriptionLabel)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let reason = state.availability.reason {
                    BrandChip(title: reason, tint: Brand.textSecondary)
                } else if let price = Price.label(for: [court], hasActiveMembership: hidesPrices) {
                    Text(price)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: Radius.inner)
            // Un terrain occupé reste lisible mais visiblement en retrait.
            .opacity(isAvailable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(accessibilityLabel(for: state))
    }

    /// Ouvre l'étape des participants. Le brouillon est réinitialisé ici : il
    /// ne doit pas conserver les joueurs d'un créneau abandonné.
    private func select(_ court: Court) {
        guard let profile = auth.sessionProfile else { return }

        draft.start(
            court: court,
            date: route.date,
            slot: route.slot,
            sport: route.sport,
            profile: profile
        )
        Haptics.tap()
        router.bookingPath.append(
            BookingParticipantsRoute(slotRoute: route, courtId: court.id)
        )
    }

    // MARK: - Données dérivées

    /// Tous les terrains du sport sur ce créneau, filtrés par la surface active.
    private var courtStates: [CourtSlotState] {
        availability
            .slots(for: route.sport, catalog: catalog)
            .first { $0.slot == route.slot }?
            .courts(surface: resolvedSurface) ?? []
    }

    private var resolvedSurface: String? {
        guard let surface = router.bookingSurface,
              catalog.surfaces(for: route.sport).contains(surface)
        else { return nil }
        return surface
    }

    private var hidesPrices: Bool {
        auth.sessionProfile?.hasActiveMembership ?? true
    }

    private func accessibilityLabel(for state: CourtSlotState) -> String {
        var parts = [state.court.nom, state.court.descriptionLabel]
        if let reason = state.availability.reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}
