//
//  CourtPickerView.swift
//  iClub
//
//  Écran 2 du tunnel : choix du terrain, l'horaire étant déjà fixé.
//
//  Contrairement à l'écran 1, *tous* les terrains du sport sont affichés, y
//  compris ceux qui ne sont pas libres, grisés et accompagnés de leur raison.
//  Masquer les terrains occupés donnerait une liste qui change de longueur d'un
//  créneau à l'autre, sans qu'on comprenne pourquoi.
//
//  Le filtre de surface reste actif ici : on peut élargir à « Tout » sans
//  revenir en arrière.
//
//  Place dans l'application
//    Poussé dans la pile de l'onglet « Réserver » par un créneau de
//    `BookingView` (`BookingSlotRoute`). Choisir un terrain libre réinitialise
//    le brouillon et pousse l'écran des joueurs (`ParticipantsView`, via
//    `BookingParticipantsRoute`).
//
//  Données
//    Grille du jour calculée par `DayAvailabilityStore` (partagé avec l'écran
//    des créneaux, donc déjà chargé et tenu à jour en temps réel) et terrains
//    du `ClubCatalog`. Les terrains fermés à la personne au nom de qui l'on
//    réserve n'apparaissent pas du tout : on n'annonce jamais un terrain caché.
//
//  Points d'attention
//    Limite connue : si le créneau passe (ou disparaît du planning) pendant
//    que l'écran est ouvert, la liste devient vide et l'écran affiche « Aucun
//    terrain sur cette surface », message qui ne correspond pas à la cause.
//

import SwiftUI

/// Destination de l'écran des participants. Le terrain est repassé par son
/// identifiant plutôt que par valeur : il est relu dans le catalogue, et donc
/// toujours à jour si l'admin l'a modifié entre-temps.
struct BookingParticipantsRoute: Hashable {
    /// Sport, jour et créneau choisis à l'écran 1.
    let slotRoute: BookingSlotRoute
    /// Terrain choisi (`courts.id`).
    let courtId: UUID
}

/// Écran de choix du terrain pour un créneau donné.
struct CourtPickerView: View {
    /// Sport, jour et créneau choisis à l'écran précédent.
    let route: BookingSlotRoute
    /// Réservations et blocages du jour, partagés avec l'écran des créneaux.
    let availability: DayAvailabilityStore
    /// Brouillon du tunnel, réinitialisé au choix d'un terrain.
    let draft: BookingDraft

    /// Session : profil actif (premier joueur, affichage des prix).
    @Environment(AuthController.self) private var auth
    /// Catalogue : terrains réservables et surfaces du sport.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : pile de l'onglet et surface retenue.
    @Environment(AppRouter.self) private var router

    /// En-tête du créneau, filtre de surface, liste des terrains.
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
        // Titre de la barre : l'heure de début (« 14 h 00 »).
        .navigationTitle(route.slot.startLabel)
        .navigationBarTitleDisplayMode(.inline)
        // « Tirer pour actualiser » : relit réservations et blocages du jour.
        .refreshable { await availability.reload() }
    }

    // MARK: - En-tête

    /// Date complète en petites capitales, puis l'horaire du créneau.
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

    /// Filtre de surface, seulement si le sport en a au moins deux. La
    /// sélection est celle du routeur, commune avec l'écran des créneaux.
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
            // La barre déborde jusqu'aux bords de l'écran.
            .padding(.horizontal, -20)
        }
    }

    // MARK: - Terrains

    /// Liste des terrains du créneau, ou carte vide si aucun ne correspond à
    /// la surface choisie.
    @ViewBuilder
    private var courtList: some View {
        let states = courtStates

        if states.isEmpty {
            // Aucun terrain pour ce créneau et cette surface.
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
            // Un bouton par terrain, dans l'ordre choisi par l'admin.
            LazyVStack(spacing: 8) {
                ForEach(states) { state in
                    courtRow(state)
                }
            }
        }
    }

    /// Rangée d'un terrain : pictogramme, nom, description (surface, intérieur
    /// ou extérieur, éclairage), puis la raison s'il est pris, ou le prix par
    /// joueur s'il est libre et que le membre n'a pas d'adhésion active.
    ///
    /// - Parameter state: terrain et sa disponibilité sur le créneau.
    /// - Returns: le bouton du terrain, inactif et estompé s'il n'est pas libre.
    private func courtRow(_ state: CourtSlotState) -> some View {
        let court = state.court
        let isAvailable = state.isAvailable

        return Button {
            select(court)
        } label: {
            HStack(spacing: 12) {
                // Pictogramme du sport, gris si le terrain est pris.
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

                    // « Terre battue · Extérieur · Éclairé ».
                    Text(court.descriptionLabel)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Raison de l'indisponibilité (« Réservé », « Cours »,
                // libellé saisi par l'admin), sinon le prix éventuel.
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
    ///
    /// - Parameter court: terrain libre choisi.
    private func select(_ court: Court) {
        // Le premier joueur est celui au nom duquel on réserve : soi, ou
        // l'enfant sélectionné. Le créateur reste le compte connecté.
        guard let profile = auth.activeProfile else { return }

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
    /// Le créneau est retrouvé dans la grille par égalité (début et durée).
    private var courtStates: [CourtSlotState] {
        availability
            .slots(for: route.sport, catalog: catalog)
            .first { $0.slot == route.slot }?
            .courts(surface: resolvedSurface) ?? []
    }

    /// Surface retenue par le routeur, ramenée à « Tout » (`nil`) si elle
    /// n'existe plus pour ce sport.
    private var resolvedSurface: String? {
        guard let surface = router.bookingSurface,
              catalog.surfaces(for: route.sport).contains(surface)
        else { return nil }
        return surface
    }

    /// Masque les prix pour un membre à l'adhésion active, et par prudence
    /// quand aucun profil n'est connu (voir `BookingView.hidesPrices`).
    private var hidesPrices: Bool {
        auth.activeProfile?.hasActiveMembership ?? true
    }

    /// Libellé VoiceOver : nom, description et raison d'indisponibilité.
    ///
    /// - Parameter state: terrain et sa disponibilité.
    /// - Returns: « Central, Terre battue · Extérieur, Réservé ».
    private func accessibilityLabel(for state: CourtSlotState) -> String {
        var parts = [state.court.nom, state.court.descriptionLabel]
        if let reason = state.availability.reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}
