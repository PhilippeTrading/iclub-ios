//
//  OpenGameCreateFlow.swift
//  iClub
//
//  Tunnel d'ouverture d'une partie : sport → créneau → terrain → réglages.
//
//  Le choix du créneau réutilise les composants du planning classique
//  (`DayAvailabilityStore`, `DayStrip`, `SurfaceFilterBar`, `SlotRow`) : une
//  partie ouverte étant une réservation, il n'y a aucune raison d'avoir deux
//  moteurs de disponibilité qui pourraient diverger entre eux.
//
//  Un bandeau rappelle en permanence que le créneau choisi sera réservé au nom
//  du membre : il bloque le terrain dès la création, avant que quiconque ait
//  rejoint.
//
//  Place dans l'application
//    Onglet « Parties ». `OpenGamesView` (hors de ce fichier) déclare les
//    destinations de navigation de toutes les routes ci-dessous et propose le
//    bouton « Ouvrir une partie », masqué quand on agit pour un enfant : une
//    partie s'ouvre toujours au nom du compte connecté. Les écrans de ce
//    fichier sont les trois premières étapes ; la quatrième, les réglages et
//    la création, est `OpenGameFormView`.
//
//  Données
//    Sports et terrains réservables par la personne (`ClubCatalog`, terrains
//    fermés exclus), réservations et blocages du jour (`DayAvailabilityStore`,
//    une instance par écran). Rien n'est écrit ici.
//
//  Règles, et ce que la base revérifie
//    À la création (`OpenGameService.create`), la base refuse un créneau déjà
//    pris à la même heure de début (index unique), un terrain fermé à l'hôte
//    (déclencheur `acces_terrain`) et une seconde partie ouverte le même jour
//    (déclencheur `one_open_game_per_day`). L'obligation d'avoir renseigné son
//    classement n'est vérifiée que par l'app (`OpenGameEligibility`).
//

import SwiftUI

// MARK: - Routes

/// Première étape du tunnel d'ouverture : le choix du sport. Sans donnée.
struct OpenGameSportRoute: Hashable {}

/// Détail d'une partie, ouvert depuis une notification.
/// Également depuis l'historique des notifications.
struct OpenGameDetailRoute: Hashable {
    /// Identifiant de la réservation de la partie (`reservations.id`).
    let gameId: UUID
}

/// Deuxième étape : le choix du créneau, pour un sport.
struct OpenGameSlotRoute: Hashable {
    /// Sport choisi.
    let sport: Sport
}

/// Quatrième étape : les réglages de la partie (niveau, mixité, ambiance)
/// et sa création, sur un terrain et un créneau choisis.
struct OpenGameFormRoute: Hashable {
    /// Sport choisi.
    let sport: Sport
    /// Jour choisi (début de journée, fuseau de l'appareil).
    let date: Date
    /// Créneau choisi.
    let slot: TimeSlot
    /// Terrain choisi (`courts.id`), relu dans le catalogue à l'affichage.
    let courtId: UUID
}

// MARK: - Choix du sport

/// Écran « Ouvrir une partie » : un bouton par sport du club, grisé quand
/// aucun de ses terrains n'est réservable par la personne.
struct OpenGameSportPickerView: View {
    /// Catalogue : sports et nombre de terrains réservables.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : pile de l'onglet « Parties ».
    @Environment(AppRouter.self) private var router

    /// Sports ayant au moins un terrain actif.
    private var sports: [Sport] { catalog.availableSports }

    /// Bandeau, question, puis un bouton par sport.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banner

                Text("Pour quel sport ?")
                    .metaLabelStyle()

                // Un bouton par sport, qui pousse le choix du créneau.
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
                    // Aucun terrain réservable dans ce sport : rien à ouvrir.
                    .disabled(catalog.courtCount(for: sport) == 0)
                    .opacity(catalog.courtCount(for: sport) == 0 ? 0.5 : 1)
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

    /// Nombre de terrains réservables, ou explication quand il n'y en a aucun.
    ///
    /// - Parameter sport: sport concerné.
    /// - Returns: « 3 terrains », « 1 terrain », ou « Aucun terrain de padel à
    ///   réserver. ».
    private func courtCountLabel(_ sport: Sport) -> String {
        let count = catalog.courtCount(for: sport)
        if count == 0 { return "Aucun terrain de \(sport.displayName.lowercased()) à réserver." }
        return count > 1 ? "\(count) terrains" : "\(count) terrain"
    }

    /// Bandeau d'explication commun aux trois étapes.
    private var banner: some View {
        OpenGameModeBanner()
    }
}

/// Bandeau rappelant l'effet de l'ouverture d'une partie.
/// Le créneau est réservé au nom du membre dès la création, puis proposé aux
/// autres.
struct OpenGameModeBanner: View {
    /// Pictogramme d'information et phrase, sur fond vert pâle.
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

/// Deuxième étape : jour et créneau libres du sport, comme dans le tunnel de
/// réservation, mais sans prix.
struct OpenGameSlotPickerView: View {
    /// Sport choisi à l'étape précédente.
    let sport: Sport

    /// Session : club du compte connecté.
    @Environment(AuthController.self) private var auth
    /// Catalogue : terrains, horaires, horizon, surfaces.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : pile de l'onglet « Parties ».
    @Environment(AppRouter.self) private var router

    /// Réservations et blocages du jour affiché, propres à cet écran.
    @State private var availability = DayAvailabilityStore()
    /// Jour touché dans la bande ; `nil` signifie aujourd'hui. Gardé ici, et
    /// non dans le routeur comme le tunnel de réservation.
    @State private var selectedDay: Date?
    /// Surface filtrée ; `nil` pour toutes.
    @State private var surface: String?

    /// Jours réservables du sport : aujourd'hui puis `horizon_jours` jours.
    private var days: [Date] {
        DayStrip.days(horizonJours: catalog.settings(for: sport).horizonJours)
    }

    /// Jour affiché : le jour touché s'il est dans l'horizon, sinon
    /// aujourd'hui.
    private var day: Date {
        let calendar = Calendar.current
        if let selectedDay,
           let match = days.first(where: { calendar.isDate($0, inSameDayAs: selectedDay) }) {
            return match
        }
        return days.first ?? calendar.startOfDay(for: .now)
    }

    /// Bandeau, filtre de surface, bande de jours, liste des créneaux.
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
        // Chargement et écoute temps réel, relancés à chaque changement de jour.
        .task(id: availabilityKey) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await availability.activate(clubId: clubId, date: day)
        }
        // « Tirer pour actualiser » : catalogue, puis disponibilités du jour.
        .refreshable {
            await catalog.reload()
            await availability.reload()
        }
    }

    /// Filtre de surface, seulement si le sport en a au moins deux.
    @ViewBuilder
    private var surfaceBar: some View {
        let surfaces = catalog.surfaces(for: sport)
        if surfaces.count > 1 {
            SurfaceFilterBar(surfaces: surfaces, accent: sport.accent, selection: $surface)
        }
    }

    /// Bande des jours réservables.
    private var dayStrip: some View {
        DayStrip(
            days: days,
            accent: sport.accent,
            selection: Binding(get: { day }, set: { selectedDay = $0 })
        )
    }

    /// Liste des créneaux libres, ou l'état qui en tient lieu (erreur,
    /// chargement, journée pleine).
    @ViewBuilder
    private var slotList: some View {
        let rows = openSlots

        if case .failed(let message) = availability.phase {
            // Disponibilités illisibles : erreur et nouvelle tentative.
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
            // Lecture en cours : cinq rangées fantômes.
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonBlock(height: 62, cornerRadius: Radius.inner)
                }
            }
            .padding(.horizontal, 20)
        } else if rows.isEmpty {
            // Aucun créneau libre ce jour-là.
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
            // Un lien par créneau libre, vers le choix du terrain.
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

    /// Créneaux ayant au moins un terrain libre sur la surface filtrée, avec
    /// ces terrains dans l'ordre choisi par l'admin.
    private var openSlots: [(slot: TimeSlot, courts: [Court])] {
        availability.slots(for: sport, catalog: catalog).compactMap { entry in
            let free = entry.availableCourts(surface: resolvedSurface).map(\.court)
            return free.isEmpty ? nil : (entry.slot, free)
        }
    }

    /// Surface filtrée, ramenée à « Tout » si elle n'existe plus pour ce sport.
    private var resolvedSurface: String? {
        guard let surface, catalog.surfaces(for: sport).contains(surface) else { return nil }
        return surface
    }

    /// Clé de rechargement : club et jour (« identifiant|2026-09-23 »).
    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: day))"
    }
}

// MARK: - Choix du terrain

/// Troisième étape : le choix du terrain, pour un sport, un jour et un créneau.
struct OpenGameCourtRoute: Hashable {
    /// Sport choisi.
    let sport: Sport
    /// Jour choisi.
    let date: Date
    /// Créneau choisi.
    let slot: TimeSlot
}

/// Troisième étape : tous les terrains réservables du sport sur le créneau,
/// les occupés grisés avec leur raison.
///
/// Le filtre de surface de l'écran précédent n'est pas repris ici : tous les
/// terrains du sport sont listés. Limite connue : si le créneau disparaît du
/// planning (passé, ou plus aucun terrain), la liste reste vide sans message.
struct OpenGameCourtPickerView: View {
    /// Sport, jour et créneau choisis.
    let route: OpenGameCourtRoute

    /// Session : club du compte connecté.
    @Environment(AuthController.self) private var auth
    /// Catalogue : terrains réservables du sport.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : pile de l'onglet « Parties ».
    @Environment(AppRouter.self) private var router

    /// Réservations et blocages du jour, relus pour cet écran.
    @State private var availability = DayAvailabilityStore()

    /// Bandeau, en-tête du créneau, liste des terrains.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OpenGameModeBanner()

                // Date complète, puis l'horaire du créneau.
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
        // Chargement et écoute temps réel des disponibilités du jour.
        .task(id: availabilityKey) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await availability.activate(clubId: clubId, date: route.date)
        }
        .refreshable { await availability.reload() }
    }

    /// Un bouton par terrain du créneau : libre (vers les réglages de la
    /// partie) ou grisé avec sa raison (« Réservé », « Cours »...).
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
                    // Double garde avec `.disabled` : un terrain pris ne mène
                    // nulle part.
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
                        // Pictogramme du sport, gris si le terrain est pris.
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

                        // Raison de l'indisponibilité.
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

    /// Clé de rechargement : club et jour.
    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: route.date))"
    }
}
