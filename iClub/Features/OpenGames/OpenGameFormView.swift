//
//  OpenGameFormView.swift
//  iClub
//
//  Réglages de la partie : format, niveau recherché, mixité, ambiance.
//
//  Deux blocages sont évalués *avant* toute saisie et remplacent le formulaire
//  entier : classement non renseigné pour ce sport, et partie déjà en cours ce
//  jour-là. Laisser remplir un formulaire voué à l'échec serait une perte de
//  temps doublée d'une erreur incompréhensible à la fin.
//

import SwiftUI

struct OpenGameFormView: View {
    let route: OpenGameFormRoute
    let court: Court
    let store: OpenGamesStore

    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var format: GameFormat = .simple
    @State private var allLevels = false
    @State private var minLevel = ""
    @State private var maxLevel = ""
    @State private var mixite: Mixite = .mixte
    @State private var ambiance: Ambiance = .loisir

    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var slotTaken = false
    @State private var hasPrepared = false

    private var profile: SessionProfile? { auth.sessionProfile }
    private var sport: Sport { route.sport }
    private var scale: [String] { Ranking.scale(for: sport) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recap

                if let block = creationBlock {
                    blockNotice(block)
                } else {
                    formatSection
                    levelSection
                    mixitySection
                    ambianceSection

                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }
                }

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Ouvrir une partie")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if creationBlock == nil { confirmBar }
        }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        .alert("Créneau indisponible", isPresented: $slotTaken) {
            Button("Choisir un autre créneau") {
                router.openGamesPath = NavigationPath()
            }
        } message: {
            Text(OpenGameError.slotAlreadyTaken.localizedDescription)
        }
        .task { prepare() }
    }

    // MARK: - Préparation

    /// Valeurs initiales : format imposé au padel, fourchette centrée sur le
    /// classement de l'hôte, mixité limitée à ce qu'il peut rejoindre.
    private func prepare() {
        guard !hasPrepared, let profile else { return }
        hasPrepared = true

        format = GameFormat.preferred(for: sport)

        if Ranking.hasScale(sport),
           let mine = Ranking.memberRanking(profile, sport: sport),
           let suggested = Ranking.suggestedRange(around: mine, sport: sport) {
            minLevel = suggested.min
            maxLevel = suggested.max
            allLevels = false
        } else {
            // Pickleball : aucun classement au club, donc toujours tous niveaux.
            allLevels = true
        }

        mixite = .mixte
    }

    // MARK: - Blocages

    private var creationBlock: OpenGameEligibility.CreationBlock? {
        guard let profile else { return nil }
        return OpenGameEligibility.creationBlock(
            sport: sport,
            profile: profile,
            engagedSameDay: store.isEngaged(profileId: profile.id, on: route.date)
        )
    }

    private func blockNotice(_ block: OpenGameEligibility.CreationBlock) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Brand.warning)
                    Text(block.title)
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                }

                Text(block.message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                Button(block.actionTitle) {
                    router.openGamesPath = NavigationPath()
                    switch block {
                    case .missingRanking: router.selectedTab = .profile
                    case .alreadyEngagedSameDay: router.selectedTab = .openGames
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Récapitulatif

    private var recap: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(route.date.longFrenchDate)
                    .metaLabelStyle()

                Text(route.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                HStack(spacing: 8) {
                    Image(systemName: sport.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sport.accent)
                    Text(court.nom)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Format

    @ViewBuilder
    private var formatSection: some View {
        let options = GameFormat.options(for: sport)

        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .metaLabelStyle()

            if options.count == 1, let only = options.first {
                // Padel : toujours double. Une information, pas un choix.
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(sport.accent)
                    Text("\(only.displayName) · \(only.detail)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(sport.accent.opacity(0.10), in: .rect(cornerRadius: Radius.chip, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        segment(
                            title: option.displayName,
                            detail: option.detail,
                            isSelected: format == option
                        ) { format = option }
                    }
                }
            }
        }
    }

    // MARK: - Niveau

    @ViewBuilder
    private var levelSection: some View {
        if Ranking.hasScale(sport) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Niveau recherché")
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    if let mine = myRankingLabel {
                        Text("Vous : \(mine)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }

                Toggle(isOn: $allLevels) {
                    Text("Tous niveaux")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Brand.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(sport.accent)
                .padding(14)
                .surfaceCard(cornerRadius: Radius.inner)

                if !allLevels {
                    HStack(spacing: 8) {
                        levelMenu(title: "Minimum", selection: $minLevel)
                        levelMenu(title: "Maximum", selection: $maxLevel)
                    }

                    if isRangeInverted {
                        InlineMessage(
                            kind: .error,
                            message: "Le minimum doit être inférieur ou égal au maximum."
                        )
                    }
                }
            }
        }
    }

    private func levelMenu(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

            Menu {
                ForEach(scale, id: \.self) { value in
                    Button(Ranking.display(value, sport: sport)) { selection.wrappedValue = value }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Ranking.display(selection.wrappedValue, sport: sport))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .surfaceCard(cornerRadius: Radius.chip)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var myRankingLabel: String? {
        guard let profile, let mine = Ranking.memberRanking(profile, sport: sport) else { return nil }
        return Ranking.display(mine, sport: sport)
    }

    /// Une fourchette inversée est refusée : elle n'admettrait personne.
    private var isRangeInverted: Bool {
        guard !allLevels,
              let low = Ranking.index(of: minLevel, sport: sport),
              let high = Ranking.index(of: maxLevel, sport: sport)
        else { return false }
        return low > high
    }

    // MARK: - Mixité

    @ViewBuilder
    private var mixitySection: some View {
        let allowed = profile.map(OpenGameEligibility.allowedMixities) ?? [.mixte]

        VStack(alignment: .leading, spacing: 8) {
            Text("Mixité")
                .metaLabelStyle()

            HStack(spacing: 8) {
                ForEach(Mixite.allCases) { option in
                    let isAllowed = allowed.contains(option)
                    segment(
                        title: option.displayName,
                        detail: nil,
                        isSelected: mixite == option,
                        isEnabled: isAllowed
                    ) { mixite = option }
                }
            }

            Text(mixite.effect)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

            // L'hôte étant joueur, il ne peut pas ouvrir une partie dont il
            // serait lui-même exclu.
            if profile?.sexe == nil {
                InlineMessage(kind: .info, message: OpenGameEligibility.missingSexeNotice)
            }
        }
    }

    // MARK: - Ambiance

    private var ambianceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ambiance")
                .metaLabelStyle()

            HStack(spacing: 8) {
                ForEach(Ambiance.allCases) { option in
                    segment(
                        title: option.displayName,
                        detail: option.detail,
                        isSelected: ambiance == option
                    ) { ambiance = option }
                }
            }
        }
    }

    // MARK: - Segment réutilisable

    private func segment(
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 6)
            .foregroundStyle(isSelected ? Color.white : sport.accent)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? sport.accent : sport.accent.opacity(0.12))
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Création

    private var confirmBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: "Ouvrir la partie · \(format.capacity) joueurs",
                systemImage: "checkmark",
                isLoading: isCreating
            ) {
                create()
            }
            .disabled(isCreating || isRangeInverted)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private func create() {
        guard let profile else { return }
        isCreating = true
        errorMessage = nil

        // Aucune fourchette en pickleball, ni quand « tous niveaux » est actif.
        let sendsRange = !allLevels && Ranking.hasScale(sport)

        Task {
            do {
                let gameId = try await OpenGameService.create(
                    clubId: profile.clubId,
                    court: court,
                    date: route.date,
                    slot: route.slot,
                    format: format,
                    niveauMin: sendsRange ? minLevel : nil,
                    niveauMax: sendsRange ? maxLevel : nil,
                    mixite: mixite,
                    ambiance: ambiance,
                    host: profile
                )

                Haptics.success()
                await store.reload()
                isCreating = false

                // Le tunnel se referme derrière l'écran de succès.
                var path = NavigationPath()
                path.append(OpenGameConfirmation(
                    gameId: gameId,
                    courtName: court.nom,
                    sport: sport,
                    date: route.date,
                    slot: route.slot,
                    format: format,
                    levelLabel: sendsRange
                        ? Ranking.rangeLabel(min: minLevel, max: maxLevel, sport: sport)
                        : "Tous niveaux"
                ))
                router.openGamesPath = path

            } catch OpenGameError.slotAlreadyTaken {
                isCreating = false
                Haptics.failure()
                slotTaken = true
            } catch {
                isCreating = false
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
        }
    }
}
