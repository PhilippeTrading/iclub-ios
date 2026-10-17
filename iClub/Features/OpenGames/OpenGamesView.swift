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

    private var profile: SessionProfile? { auth.sessionProfile }

    private var visibleGames: [OpenGame] {
        store.openForJoining(sport: sportFilter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sportFilterBar
                content
                Spacer(minLength: 24)
            }
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Parties ouvertes")
        .safeAreaInset(edge: .bottom) { openGameBar }
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
    private var content: some View {
        if case .failed(let message) = store.phase {
            errorState(message)
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty, store.phase != .ready {
            skeletons
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 12) {
                ForEach(visibleGames) { game in
                    OpenGameCard(
                        game: game,
                        roster: store.roster,
                        myProfileId: profile?.id,
                        onSelectPlayer: { selectedPlayer = $0 },
                        onSelectFreeSlot: { team in attemptJoin(game, team: team) },
                        onJoin: { attemptJoin(game, team: game.firstTeamWithRoom) },
                        onLeave: { pendingLeave = game }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
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
                try await OpenGameService.join(game: game, team: team, side: side)
                Haptics.success()
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
