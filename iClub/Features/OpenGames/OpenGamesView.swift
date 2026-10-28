//
//  OpenGamesView.swift
//  iClub
//
//  Écran 1 : la liste des parties ouvertes.
//
//  Ne sont affichées que les parties qu'on peut encore rejoindre. Une partie
//  complète, commencée ou annulée disparaît d'ici et ne vit plus que dans
//  « Mes réservations » — c'est de là qu'on la quitte.
//

import SwiftUI

struct OpenGamesView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var store = OpenGamesStore()
    @State private var sportFilter: Sport?

    /// Joueur dont la fiche est ouverte.
    @State private var selectedPlayer: OpenGame.Player?
    /// Refus d'admission à expliquer, dans une fenêtre.
    @State private var refusal: OpenGameEligibility.Refusal?
    /// Partie et équipe en attente du choix de position (padel).
    @State private var pendingSide: (game: OpenGame, team: Team?)?
    @State private var isJoining = false
    @State private var joinError: String?
    /// Partie dont la sortie attend confirmation : annulation si j'en suis
    /// l'hôte, simple départ sinon.
    @State private var pendingLeave: OpenGame?
    /// Vrai après une première partie rejointe : moment où l'on propose les
    /// notifications.
    @State private var didJoin = false

    /// Le compte au nom duquel on agit : le sien, ou celui d'un enfant.
    private var profile: SessionProfile? { auth.activeProfile }

    /// Position du haut de chaque journée, et du bas de l'en-tête figé, dans
    /// le repère de la liste : la journée en surbrillance est la dernière
    /// passée sous l'en-tête.
    @State private var sectionTops: [Date: CGFloat] = [:]
    @State private var headerBottom: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    /// Jour touché dans la bande, tenu en surbrillance le temps du défilement
    /// qu'il déclenche — sinon la sélection passerait par tous les jours
    /// intermédiaires.
    @State private var pendingDay: Date?
    /// Hauteurs utiles pour que la dernière section puisse remonter jusqu'en
    /// haut : sans cela, toucher le dernier jour ne l'amènerait pas sous la
    /// bande, et la sélection retomberait sur la veille.
    @State private var viewportHeight: CGFloat = 0
    @State private var lastSectionHeight: CGFloat = 0
    /// Cartes dépliées. Toutes repliées par défaut : la liste se parcourt
    /// d'un coup d'œil.
    @State private var expandedGames: Set<UUID> = []

    private var visibleGames: [OpenGame] {
        store.openForJoining(sport: sportFilter)
    }

    /// Parties regroupées par jour, dans l'ordre chronologique.
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleGames) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            DaySection(day: day, games: grouped[day, default: []].sorted { $0.startsAt < $1.startsAt })
        }
    }

    var body: some View {
        let sections = daySections

        ScrollViewReader { proxy in
            ScrollView {
                // L'en-tête est un en-tête de section épinglé, et non un
                // encart hors de la liste : le grand titre garde ainsi sa
                // taille et sa place, et se replie au défilement comme sur les
                // autres onglets.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        content(sections)
                            .padding(.top, 8)
                    } header: {
                        header(sections, proxy: proxy)
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            } action: { _, height in
                viewportHeight = height
            }
            .onScrollPhaseChange { _, phase in
                // Fin du défilement déclenché par la bande, ou reprise en
                // main : la position réelle reprend la main.
                if phase == .idle || phase == .interacting { pendingDay = nil }
            }
            // Un autre sport n'a pas forcément de partie le jour affiché : on
            // repart du premier jour.
            .onChange(of: sportFilter) { _, _ in
                sectionTops = [:]
                pendingDay = nil
                if let first = daySections.first?.day {
                    proxy.scrollTo(DayAnchor(day: first), anchor: .top)
                }
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Parties ouvertes")
        // Ouvrir une partie se fait en son propre nom : la barre disparaît
        // quand on agit pour un enfant.
        .safeAreaInset(edge: .bottom) {
            if !auth.isActingForChild { openGameBar }
        }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Les quatre étapes du tunnel d'ouverture sont déclarées à la racine :
        // le magasin reste un objet unique, partagé par tous les écrans.
        .navigationDestination(for: OpenGameSportRoute.self) { _ in
            OpenGameSportPickerView()
        }
        .navigationDestination(for: OpenGameSlotRoute.self) { route in
            OpenGameSlotPickerView(sport: route.sport)
        }
        .navigationDestination(for: OpenGameCourtRoute.self) { route in
            OpenGameCourtPickerView(route: route)
        }
        .navigationDestination(for: OpenGameFormRoute.self) { route in
            formDestination(route)
        }
        .navigationDestination(for: OpenGameConfirmation.self) { confirmation in
            OpenGameConfirmedView(confirmation: confirmation)
        }
        // Ouverte depuis une notification : la partie annoncée, directement.
        .navigationDestination(for: OpenGameDetailRoute.self) { route in
            detailDestination(route)
        }
        .task(id: profile?.clubId) {
            guard let clubId = profile?.clubId else { return }
            await store.activate(clubId: clubId)
        }
        .refreshable { await store.reload() }
        .sheet(item: $selectedPlayer) { player in
            PlayerProfileSheet(player: player, info: store.roster[player.profileId])
        }
        .sheet(isPresented: sidePickerBinding) {
            if let pendingSide {
                SidePickerSheet(
                    team: pendingSide.team,
                    accent: pendingSide.game.sport.accent
                ) { side in
                    join(pendingSide.game, team: pendingSide.team, side: side)
                }
            }
        }
        .alert(refusal?.title ?? "", isPresented: refusalBinding) {
            Button("J'ai compris") { refusal = nil }
        } message: {
            Text(refusal?.message ?? "")
        }
        .confirmationDialog(
            leaveTitle,
            isPresented: leaveConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingLeave
        ) { game in
            Button(OpenGame.actionTitle(for: game.role(for: profile?.id)), role: .destructive) {
                leave(game)
            }
            Button("Conserver", role: .cancel) {}
        } message: { game in
            Text(leaveMessage(for: game))
        }
        .alert("Action impossible", isPresented: joinErrorBinding) {
            Button("OK") { joinError = nil }
        } message: {
            Text(joinError ?? "")
        }
        .overlay {
            if isJoining {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .overlay { ProgressView() }
            }
        }
        .animation(.smooth(duration: 0.3), value: sportFilter)
        .offersNotificationOptIn(when: didJoin)
    }

    /// Le terrain est relu dans le catalogue à l'affichage : s'il a été
    /// désactivé pendant que le membre réglait sa partie, on le dit plutôt que
    /// d'ouvrir un formulaire qui échouera.
    @ViewBuilder
    private func formDestination(_ route: OpenGameFormRoute) -> some View {
        if let court = catalog.courts(for: route.sport).first(where: { $0.id == route.courtId }) {
            OpenGameFormView(route: route, court: court, store: store)
        } else {
            PhasePlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Terrain indisponible",
                message: "Ce terrain vient d'être retiré de la réservation. Choisis-en un autre.",
                accent: Brand.warning
            )
        }
    }

    // MARK: - En-tête figé

    @ViewBuilder
    private func header(_ sections: [DaySection], proxy: ScrollViewProxy) -> some View {
        let gameDays = Set(sections.map(\.day))

        if !sections.isEmpty || store.sportsWithGames.count > 1 {
            VStack(spacing: 10) {
                sportFilterBar

                if !sections.isEmpty {
                    DayStrip(
                        days: stripDays(sections),
                        accent: sportFilter?.accent ?? Brand.navy700,
                        selection: daySelection(sections, proxy: proxy),
                        isEnabled: { gameDays.contains($0) }
                    )
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Brand.background)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                headerBottom = frame.maxY
                headerHeight = frame.height
            }
        }
    }

    /// Une semaine au moins à partir d'aujourd'hui, prolongée jusqu'au
    /// dernier jour qui a une partie.
    private func stripDays(_ sections: [DaySection]) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let lastDay = sections.last?.day ?? today
        let span = max(6, calendar.dateComponents([.day], from: today, to: lastDay).day ?? 0)
        return DayStrip.days(horizonJours: span, from: today)
    }

    /// Toucher un jour fait défiler la liste jusqu'à lui ; défiler la liste
    /// met à jour le jour en surbrillance.
    private func daySelection(_ sections: [DaySection], proxy: ScrollViewProxy) -> Binding<Date> {
        Binding(
            get: { currentDay(sections) ?? Calendar.current.startOfDay(for: .now) },
            set: { day in
                pendingDay = day
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(DayAnchor(day: day), anchor: .top)
                }
            }
        )
    }

    /// Dernière journée dont le haut est passé sous l'en-tête figé.
    private func currentDay(_ sections: [DaySection]) -> Date? {
        if let pendingDay { return pendingDay }
        let threshold = headerBottom + 8
        return sections.last { (sectionTops[$0.day] ?? .infinity) <= threshold }?.day
            ?? sections.first?.day
    }

    // MARK: - Filtres

    @ViewBuilder
    private var sportFilterBar: some View {
        let sports = store.sportsWithGames

        // Un seul sport concerné : le filtre n'aurait rien à filtrer.
        if sports.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    filterChip(title: "Tous les sports", sport: nil, tint: Brand.navy700)
                    ForEach(sports) { sport in
                        filterChip(title: sport.displayName, sport: sport, tint: sport.accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func filterChip(title: String, sport: Sport?, tint: Color) -> some View {
        let isSelected = sportFilter == sport

        return Button {
            guard !isSelected else { return }
            sportFilter = sport
            Haptics.selection()
        } label: {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : tint)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? tint : tint.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Contenu

    @ViewBuilder
    private func content(_ sections: [DaySection]) -> some View {
        if case .failed(let message) = store.phase {
            errorState(message)
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty, store.phase != .ready {
            skeletons
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty {
            emptyState
        } else {
            // Pile ordinaire et non paresseuse : une journée hors écran doit
            // déjà exister pour que la bande puisse y faire défiler. En pile
            // paresseuse, les jours lointains n'étaient pas encore construits
            // (visible avec « Tous les sports », où les parties sont nombreuses)
            // et le tap sur leur pastille ne menait nulle part.
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    daySection(section, isLast: section.id == sections.last?.id)
                }
            }
            .padding(.horizontal, 20)

            // Laisse au dernier jour la place de remonter sous la bande.
            Color.clear
                .frame(height: max(24, viewportHeight - headerHeight - lastSectionHeight - 8))
        }
    }

    private func daySection(_ section: DaySection, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DayHeader(day: section.day)
            ForEach(section.games) { game in
                card(for: game, isExpanded: expandedGames.contains(game.id)) {
                    withAnimation(.smooth(duration: 0.3)) {
                        if expandedGames.remove(game.id) == nil { expandedGames.insert(game.id) }
                    }
                    Haptics.selection()
                }
            }
        }
        // Cible du défilement, posée juste au-dessus de la journée et haute
        // comme l'en-tête : amenée en haut, elle laisse la journée apparaître
        // pile sous l'en-tête épinglé, au lieu de passer dessous.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: headerHeight + 8)
                .alignmentGuide(.top) { $0[.bottom] }
                .id(DayAnchor(day: section.day))
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            sectionTops[section.day] = frame.minY
            if isLast { lastSectionHeight = frame.height }
        }
    }

    private func card(
        for game: OpenGame,
        isExpanded: Bool = true,
        onToggleExpanded: (() -> Void)? = nil
    ) -> some View {
        OpenGameCard(
            game: game,
            roster: store.roster,
            myProfileId: profile?.id,
            onSelectPlayer: { selectedPlayer = $0 },
            onSelectFreeSlot: { team in attemptJoin(game, team: team) },
            onJoin: { attemptJoin(game, team: game.firstTeamWithRoom) },
            onLeave: { pendingLeave = game },
            isExpanded: isExpanded,
            onToggleExpanded: onToggleExpanded
        )
    }

    // MARK: - Détail (depuis une notification)

    /// Même carte que dans la liste, avec les mêmes actions : rejoindre se
    /// fait en un geste, sans chercher la partie.
    ///
    /// La partie est lue dans le magasin, tenu à jour en temps réel : si elle
    /// se remplit entre la notification et le tap, on le dit.
    @ViewBuilder
    private func detailDestination(_ route: OpenGameDetailRoute) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if let game = store.game(id: route.gameId) {
                    if let status = unavailableStatus(of: game) {
                        InlineMessage(kind: .info, message: status)
                    }
                    card(for: game)
                } else if store.phase == .ready {
                    PhasePlaceholder(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "Partie plus proposée",
                        message: "Elle a été annulée ou a déjà eu lieu. D'autres parties vous attendent peut-être.",
                        accent: Brand.warning
                    )
                    Button("Voir les parties ouvertes") {
                        router.openGamesPath = NavigationPath()
                    }
                    .buttonStyle(.glass)
                } else if case .failed(let message) = store.phase {
                    errorState(message)
                } else {
                    SkeletonBlock(height: 230, cornerRadius: Radius.card)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Partie ouverte")
        .navigationBarTitleDisplayMode(.inline)
        // La racine de la pile n'est pas forcément apparue quand on arrive ici
        // à froid : on s'assure que les parties sont chargées.
        .task(id: profile?.clubId) {
            guard let clubId = profile?.clubId else { return }
            await store.ensureLoaded(clubId: clubId)
        }
    }

    private func unavailableStatus(of game: OpenGame) -> String? {
        // J'y suis déjà : la carte montre elle-même mon rôle.
        if let myId = profile?.id, game.contains(myId) { return nil }
        if game.isCancelled { return "Cette partie a été annulée." }
        if game.hasStarted { return "Cette partie a déjà commencé." }
        if game.isFull { return "Cette partie vient d'être complétée." }
        return nil
    }

    private var skeletons: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonBlock(height: 230, cornerRadius: Radius.card)
            }
        }
    }

    private var emptyState: some View {
        PhasePlaceholder(
            systemImage: "figure.tennis.circle",
            title: sportFilter == nil ? "Aucune partie ouverte" : "Aucune partie dans ce sport",
            message: "Ouvre la tienne : réserve un créneau et laisse les places libres aux autres membres.",
            accent: Brand.pine800
        )
    }

    private func errorState(_ message: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Parties indisponibles")
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Button("Réessayer") {
                    Task { await store.reload() }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Ouvrir une partie

    private var openGameBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(title: "Ouvrir une partie", systemImage: "plus") {
                router.openGamesPath.append(OpenGameSportRoute())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    // MARK: - Rejoindre

    /// Vérifie les règles *avant* d'envoyer la requête : un refus s'explique
    /// dans une fenêtre, il ne se découvre pas au retour d'une erreur technique.
    private func attemptJoin(_ game: OpenGame, team: Team?) {
        guard let profile else { return }

        if let reason = OpenGameEligibility.refusal(
            joining: game,
            profile: profile,
            engagedSameDay: store.isEngaged(
                profileId: profile.id,
                on: game.date,
                excluding: game.id
            )
        ) {
            refusal = reason
            Haptics.warning()
            return
        }

        // Au padel, la position se choisit avant de rejoindre. Ailleurs on
        // rejoint directement avec « indifferent ».
        if game.usesSides {
            pendingSide = (game, team)
        } else {
            join(game, team: team, side: .indifferent)
        }
    }

    private func join(_ game: OpenGame, team: Team?, side: Side) {
        pendingSide = nil
        isJoining = true

        Task {
            do {
                try await OpenGameService.join(
                    game: game, team: team, side: side,
                    forChild: auth.isActingForChild ? profile?.id : nil
                )
                Haptics.success()
                didJoin = true
                await store.reload()
            } catch {
                // La base refait tous les contrôles sous verrou : ce chemin est
                // celui de la concurrence, et son message est déjà rédigé.
                joinError = error.localizedDescription
                Haptics.failure()
                await store.reload()
            }
            isJoining = false
        }
    }

    // MARK: - Quitter / Annuler

    private var leaveTitle: String {
        guard let pendingLeave else { return "" }
        return pendingLeave.role(for: profile?.id) == .host
            ? pendingLeave.cancelConfirmationTitle
            : pendingLeave.leaveConfirmationTitle
    }

    /// L'hôte est averti du nombre de joueurs qu'il retire ; un simple joueur
    /// est rassuré : la partie ne disparaît pas derrière lui.
    private func leaveMessage(for game: OpenGame) -> String {
        let context = "\(game.courtName) · \(game.date.longFrenchDate) · \(game.slot.label)"
        let consequence = game.role(for: profile?.id) == .host
            ? game.hostCancellationMessage
            : game.playerLeaveMessage
        return "\(context)\n\(consequence)"
    }

    private func leave(_ game: OpenGame) {
        pendingLeave = nil
        // `leave_open_game` n'agit que pour le compte connecté : la base ne
        // permet pas encore de retirer un enfant d'une partie.
        if auth.isActingForChild {
            joinError = "Pour retirer \(profile?.prenom ?? "votre enfant") de cette partie, contactez le club."
            return
        }
        isJoining = true

        Task {
            do {
                // Une seule fonction couvre les deux cas : elle retire le
                // participant, ou annule la partie si l'appelant est l'hôte.
                try await OpenGameService.leave(gameId: game.id)
                Haptics.destructive()
            } catch {
                joinError = error.localizedDescription
                Haptics.failure()
            }
            await store.reload()
            isJoining = false
        }
    }

    // MARK: - Liaisons de présentation

    private var refusalBinding: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    private var joinErrorBinding: Binding<Bool> {
        Binding(get: { joinError != nil }, set: { if !$0 { joinError = nil } })
    }

    private var sidePickerBinding: Binding<Bool> {
        Binding(get: { pendingSide != nil }, set: { if !$0 { pendingSide = nil } })
    }

    private var leaveConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } })
    }
}

/// Identifiant de défilement d'une journée, distinct de la date seule pour ne
/// pas se confondre avec d'autres vues identifiées par une date.
private struct DayAnchor: Hashable {
    let day: Date
}

/// Les parties d'une même journée.
private struct DaySection: Identifiable {
    let day: Date
    let games: [OpenGame]
    var id: Date { day }
}

/// Séparateur de jour : « Aujourd'hui », « Demain », « Samedi 24 octobre ».
private struct DayHeader: View {
    let day: Date

    var body: some View {
        Label(day.relativeFrenchDayTitle, systemImage: "calendar")
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Brand.textPrimary, in: .capsule)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `sheet(item:)` pour un modèle `Identifiable` optionnel.
private extension View {
    func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
