//
//  BookingView.swift
//  iClub
//
//  Écran 1 du tunnel : choix de l'horaire.
//
//  Logique inversée par rapport à un planning classique : on choisit d'abord un
//  créneau, ensuite un terrain. Sur mobile une grille terrains × heures est
//  illisible : 17 terrains de tennis ne tiennent pas en largeur.
//
//  Seuls les créneaux ayant au moins un terrain libre sont listés. Un horaire
//  complet, ou déjà passé sur la journée en cours, n'apparaît pas.
//
//  Place dans l'application
//    Racine de l'onglet « Réserver » (`MainTabView`), dans la pile
//    `AppRouter.bookingPath`. Le tunnel complet :
//      1. `BookingView` : sport, surface, jour et créneau ;
//      2. `CourtPickerView` : terrain ;
//      3. `ParticipantsView` : format et joueurs ;
//      4. `BookingSummaryView` : récapitulatif, paiement, confirmation ;
//      5. `BookingConfirmedView` : réservation enregistrée.
//    Les quatre destinations sont déclarées ici. L'accueil peut ouvrir cet
//    écran sur un sport donné (`AppRouter.openBooking(for:)`).
//
//  Données
//    - `ClubCatalog` : sports proposés, terrains réservables par la personne
//      (hors terrains fermés, fonction SQL `terrains_interdits`), horaires et
//      horizon de réservation (`club_sport_settings`), surfaces.
//    - `DayAvailabilityStore` : réservations confirmées et blocages du jour
//      pour tout le club, tenus à jour en temps réel.
//    - `AppRouter` : sport, jour et surface retenus, qui survivent aux
//      changements d'onglet.
//
//  États
//    Squelettes pendant le chargement du catalogue ; carte « Planning
//    indisponible » avec « Réessayer » si le catalogue ou les disponibilités
//    n'ont pas pu être lus ; « Aucun terrain ouvert » si le club n'a aucun
//    terrain actif ; message si tous les terrains du sport sont fermés à la
//    personne ; carte « Aucun créneau disponible » si la journée est pleine.
//
//  Règles appliquées ici, et ce que la base revérifie
//    - Jours proposés : d'aujourd'hui à l'horizon du sport
//      (`horizon_jours`) ; créneaux d'aujourd'hui déjà commencés masqués, à
//      l'heure de l'appareil. La base ne revérifie ni l'horizon ni l'heure.
//    - Prix par joueur masqué pour un membre à l'adhésion active.
//    - À la confirmation, la base refuse un créneau déjà pris à la même heure
//      de début (index unique) et un terrain fermé au réservataire
//      (déclencheur `acces_terrain`).
//
//  Points d'attention
//    - Attention : la grille (`AvailabilityEngine`) ne grise que le créneau qui
//      commence à l'heure de début d'un blocage ou d'une réservation ; un cours
//      plus long qu'un créneau laisse les suivants affichés libres (voir
//      DayAvailabilityStore.swift).
//    - Limite connue : les prix affichés ignorent les plages tarifaires selon
//      l'heure que le planning web applique.
//

import SwiftUI

/// Destination de navigation vers l'écran de choix du terrain.
struct BookingSlotRoute: Hashable {
    /// Sport choisi.
    let sport: Sport
    /// Jour choisi (début de journée, fuseau de l'appareil).
    let date: Date
    /// Créneau choisi (début et durée en minutes depuis minuit).
    let slot: TimeSlot
}

/// Écran de choix du créneau : sport, surface, jour, puis liste des horaires
/// ayant au moins un terrain libre.
struct BookingView: View {
    /// Session : club, profil actif (prix, terrains fermés).
    @Environment(AuthController.self) private var auth
    /// Catalogue du club : sports, terrains, horaires, surfaces.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : sport, jour et surface retenus, pile de l'onglet.
    @Environment(AppRouter.self) private var router

    /// Réservations et blocages du jour affiché, partagés avec l'écran du
    /// choix du terrain.
    @State private var availability = DayAvailabilityStore()

    /// Brouillon du tunnel. Porté par la racine : il survit aux pushes, et est
    /// réinitialisé à chaque nouvelle entrée depuis le choix du terrain.
    @State private var draft = BookingDraft()

    /// Sports proposés par le club (au moins un terrain actif), dans l'ordre
    /// tennis, padel, pickleball.
    private var sports: [Sport] { catalog.availableSports }

    /// Sport affiché : celui retenu par le routeur (choisi ici ou via une tuile
    /// de l'accueil), sinon le premier sport proposé par le club.
    private var activeSport: Sport? {
        if let sport = router.bookingSport, sports.contains(sport) { return sport }
        return sports.first
    }

    /// Colonne défilante : selon l'état du catalogue, squelettes, erreur,
    /// écran vide, ou sports, surfaces, jours et créneaux ; puis les
    /// destinations du tunnel et les chargements.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch catalog.state {
                // Catalogue pas encore chargé : squelettes.
                case .idle, .loading:
                    loadingState

                // Catalogue illisible et rien en mémoire.
                case .failed(let message):
                    errorState(message) { await catalog.reload() }

                // Aucun terrain actif dans le club.
                case .loaded where sports.isEmpty:
                    PhasePlaceholder(
                        systemImage: "figure.tennis",
                        title: "Aucun terrain ouvert",
                        message: "Le club n'a pas encore de terrain actif à la réservation."
                    )
                    .padding(.horizontal, -20)

                // Cas courant : sport, surface, jour, créneaux.
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
        // Les terrains fermés se relisent à chaque affichage du planning : le
        // club peut changer ce réglage à tout moment, sans temps réel.
        .task { await refreshCourtAccess() }
        // « Tirer pour actualiser » : terrains fermés, catalogue, puis
        // disponibilités du jour.
        .refreshable {
            await refreshCourtAccess()
            await catalog.reload()
            await availability.reload()
        }
        .animation(.smooth(duration: 0.3), value: activeSport)
    }

    /// Le terrain est relu dans le catalogue à l'affichage : s'il a été
    /// désactivé par l'admin pendant que l'utilisateur composait sa partie, on
    /// le dit plutôt que d'ouvrir un tunnel qui échouera à la confirmation.
    /// Un terrain devenu fermé à la personne est traité de la même façon.
    ///
    /// - Parameter route: créneau et terrain choisis.
    /// - Returns: l'écran des joueurs, ou un écran « Terrain indisponible ».
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

    /// Pastilles des sports du club ; le choix est retenu par le routeur.
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
                    // Fond plein de la couleur du sport choisi, teinté sinon.
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

    /// Filtre de surface du sport, absent quand il n'y a qu'une surface.
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: la barre de filtre, ou rien.
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

    /// Bande des jours réservables du sport ; le jour choisi est retenu par le
    /// routeur.
    ///
    /// - Parameter sport: sport affiché, dont l'horizon fixe la longueur.
    /// - Returns: la bande de jours.
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

    /// Liste des créneaux libres du jour, ou l'état qui en tient lieu.
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: la liste, ou un message (aucun terrain, erreur, chargement,
    ///   journée pleine).
    @ViewBuilder
    private func slotList(for sport: Sport) -> some View {
        let surface = resolvedSurface(for: sport)
        let rows = openSlots(for: sport, surface: surface)

        // Tous les terrains du sport sont fermés à cette personne : on garde le
        // sport, sans dire pourquoi, avec le texte du web.
        if catalog.courts(for: sport).isEmpty {
            noCourtState(sport)
        } else if case .failed(let message) = availability.phase {
            // Disponibilités illisibles : erreur franche plutôt que des
            // créneaux peut-être faux.
            errorState(message) { await availability.reload() }
        } else if rows.isEmpty, availability.phase != .ready {
            // Rien encore à montrer et lecture en cours.
            slotSkeletons
        } else if rows.isEmpty {
            // Journée pleine (ou passée) pour ce sport et cette surface.
            emptySlotState(surface: surface)
        } else {
            // Un lien par créneau libre, vers le choix du terrain.
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

    /// Message quand aucun terrain du sport n'est réservable par la personne.
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: le texte centré.
    private func noCourtState(_ sport: Sport) -> some View {
        Text("Aucun terrain de \(sport.displayName.lowercased()) à réserver.")
            .font(.subheadline)
            .foregroundStyle(Brand.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 32)
    }

    /// Relit les terrains fermés pour la personne au nom de qui l'on réserve :
    /// l'enfant sélectionné, ou soi-même.
    private func refreshCourtAccess() async {
        await catalog.refreshAccess(childId: auth.isActingForChild ? auth.activeProfile?.id : nil)
    }

    /// Créneaux ayant au moins un terrain libre après filtre de surface, avec
    /// la liste de ces terrains dans l'ordre `courts.ordre`.
    ///
    /// - Parameters:
    ///   - sport: sport affiché.
    ///   - surface: surface retenue, `nil` pour toutes.
    /// - Returns: un couple (créneau, terrains libres) par créneau proposé,
    ///   triés par heure.
    private func openSlots(for sport: Sport, surface: String?) -> [(slot: TimeSlot, courts: [Court])] {
        availability.slots(for: sport, catalog: catalog).compactMap { entry in
            let free = entry.availableCourts(surface: surface).map(\.court)
            return free.isEmpty ? nil : (entry.slot, free)
        }
    }

    // MARK: - Jour et surface retenus

    /// Jours réservables du sport : aujourd'hui puis `horizon_jours` jours.
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: les jours, à minuit, fuseau de l'appareil.
    private func days(for sport: Sport) -> [Date] {
        DayStrip.days(horizonJours: catalog.settings(for: sport).horizonJours)
    }

    /// Le jour retenu doit toujours appartenir à l'horizon du sport affiché :
    /// un sport réservable 14 jours à l'avance puis un autre limité à 2 jours
    /// laisserait sinon une date hors plage sélectionnée.
    /// Sans jour retenu (`nil` dans le routeur), ou hors plage : aujourd'hui.
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
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: la surface retenue, ou `nil` pour « Tout ».
    private func resolvedSurface(for sport: Sport) -> String? {
        guard let surface = router.bookingSurface,
              catalog.surfaces(for: sport).contains(surface)
        else { return nil }
        return surface
    }

    /// Liaison du filtre de surface avec le routeur, à travers la règle de
    /// `resolvedSurface`.
    ///
    /// - Parameter sport: sport affiché.
    /// - Returns: la liaison lue et écrite par `SurfaceFilterBar`.
    private func surfaceBinding(for sport: Sport) -> Binding<String?> {
        Binding(
            get: { resolvedSurface(for: sport) },
            set: { router.bookingSurface = $0 }
        )
    }

    /// Clé de rechargement : le club et le jour. Le sport est absent
    /// volontairement, les réservations étant lues pour l'ensemble du club.
    /// Forme : « identifiant du club|2026-09-23 ».
    private var availabilityKey: String {
        let club = auth.sessionProfile?.clubId.uuidString ?? "-"
        return "\(club)|\(SupabaseDate.day(from: selectedDay))"
    }

    /// En l'absence de profil connu on masque les prix : afficher un tarif à un
    /// membre qui a une adhésion active serait une erreur plus visible que de
    /// n'afficher aucun prix.
    /// Pour un enfant sélectionné, l'adhésion est tenue pour inactive : les
    /// prix s'affichent.
    private var hidesPrices: Bool {
        auth.activeProfile?.hasActiveMembership ?? true
    }

    // MARK: - États

    /// Squelettes du premier chargement : sports, bande de jours, créneaux.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(height: 38, cornerRadius: Radius.chip)
            SkeletonBlock(height: 78, cornerRadius: Radius.chip)
            slotSkeletons
        }
        .padding(.top, 8)
    }

    /// Cinq rangées fantômes à la place de la liste des créneaux.
    private var slotSkeletons: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonBlock(height: 62, cornerRadius: Radius.inner)
            }
        }
    }

    /// Carte « Aucun créneau disponible », avec un raccourci vers « Tout »
    /// quand un filtre de surface est actif.
    ///
    /// - Parameter surface: surface filtrée, `nil` pour toutes.
    /// - Returns: la carte.
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

                // Filtre actif : un bouton pour l'enlever.
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

    /// Carte « Planning indisponible » avec un bouton « Réessayer ».
    ///
    /// - Parameters:
    ///   - message: cause de l'échec, prête à afficher.
    ///   - retry: nouvelle tentative, lancée dans une tâche au tap.
    /// - Returns: la carte.
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

/// Aperçu Xcode de l'écran, avec des objets d'environnement vides.
#Preview {
    NavigationStack { BookingView() }
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
}
