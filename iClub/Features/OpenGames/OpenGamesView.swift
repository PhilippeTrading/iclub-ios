//
//  OpenGamesView.swift
//  iClub
//
//  Écran 1 de l'onglet « Parties » : la liste des parties ouvertes du club.
//
//  Ne sont affichées que les parties qu'on peut encore rejoindre. Une partie
//  complète, commencée ou annulée disparaît d'ici et ne vit plus que dans
//  « Mes réservations » : c'est de là qu'on la quitte (l'accueil le permet
//  aussi).
//
//  Rôle
//    Racine de la pile de l'onglet « Parties ». L'écran liste les parties à
//    venir, groupées par jour, avec un filtre par sport et une bande de jours
//    épinglée qui suit le défilement. Il permet de rejoindre une partie
//    (contrôles d'admission, choix du côté au padel, écran de succès), de la
//    quitter ou de l'annuler, et d'en ouvrir une (bouton du bas). Il déclare
//    aussi les destinations de toute la pile : les quatre étapes du tunnel
//    d'ouverture, les deux écrans de succès et le détail d'une partie ouvert
//    depuis une notification.
//
//  Place dans l'application
//    - Affiché par `MainTabView` dans la `NavigationStack` liée à
//      `AppRouter.openGamesPath`, avec la barre du haut commune.
//    - Le détail d'une partie (`OpenGameDetailRoute`) est poussé à la place de
//      toute la pile par `MainTabView` (notification touchée) et par
//      l'historique des notifications (`NotificationHistory`).
//    - Écrans poussés depuis ici : `OpenGameSportPickerView`,
//      `OpenGameSlotPickerView`, `OpenGameCourtPickerView`
//      (OpenGameCreateFlow.swift), `OpenGameFormView`, `OpenGameConfirmedView`
//      (partie créée) et `BookingConfirmedView` (partie rejointe). Feuilles :
//      `PlayerProfileSheet` (fiche d'un joueur) et `SidePickerSheet` (côté au
//      padel).
//
//  Sources et tables
//    - `OpenGamesStore` : parties ouvertes confirmées du club, du jour et à
//      venir (`reservations` avec `est_partie_ouverte`, leur terrain, leurs
//      joueurs `reservation_participants`), fiches des joueurs, temps réel.
//    - `ClubCatalog` : terrains réservables et terrains fermés à la personne
//      au nom de qui l'on agit (fonction SQL `terrains_interdits`), relus à
//      chaque affichage de la liste.
//    - Écritures par `OpenGameService` : fonctions SQL `join_open_game` et
//      `leave_open_game`.
//
//  Règles métier
//    - Une partie qui se joue sur un terrain fermé à la personne (accès aux
//      terrains par groupe) est masquée, sauf si le compte connecté ou l'un des
//      enfants qu'il gère y joue déjà.
//    - Rejoindre : l'app explique d'abord les refus prévisibles (une partie
//      ouverte par jour, mixité, niveau : `OpenGameEligibility`). La fonction
//      `join_open_game` refait ensuite tous les contrôles sous verrou de ligne
//      et ajoute les siens (partie annulée, commencée ou complète, réservée aux
//      adultes, joueur déjà inscrit, droit du parent d'agir pour l'enfant), avec
//      les déclencheurs de `reservation_participants` (`one_open_game_per_day`,
//      `acces_terrain_partie` pour un terrain fermé). Ses refus arrivent déjà
//      rédigés et s'affichent tels quels.
//    - Au padel, le côté (gauche, droite, indifférent) se choisit avant de
//      rejoindre ; dans les autres sports, on rejoint « indifférent ».
//    - Quitter : `leave_open_game` retire le joueur, ou annule toute la partie
//      si l'appelant en est l'hôte. Il n'existe pas de transfert d'hôte.
//    - Ouvrir une partie et la quitter se font toujours au nom du compte
//      connecté : quand on agit pour un enfant, la barre « Ouvrir une partie »
//      disparaît et la sortie est refusée avec un message. Rejoindre, en
//      revanche, se fait au nom de l'enfant.
//
//  Droits et sécurité
//    Aucune vérification de droit dans cet écran. La RLS limite les lectures
//    aux clubs du membre ; les deux fonctions SQL (security definer) vérifient
//    l'appartenance au club et, pour un enfant, le lien de famille
//    (`peut_agir_pour`).
//
//  Effets de bord
//    Écritures en base par les deux fonctions SQL ; rappels locaux reprogrammés
//    après une partie rejointe (`BookingReminders.refresh`) ; rappel de la
//    partie retiré après une sortie (dans `OpenGameService.leave`) ;
//    proposition d'activer les notifications sur l'écran de succès d'une
//    partie rejointe (`BookingConfirmedView`, modificateur
//    `offersNotificationOptIn`) ; retours haptiques.
//
//  Points d'attention
//    - La bande de jours et la liste se pilotent l'une l'autre : les positions
//      des journées sont mesurées dans le repère du défilement, le jour touché
//      reste en surbrillance pendant le défilement qu'il déclenche, puis la
//      position est recalée une fois. La pile des journées n'est pas
//      paresseuse, pour que chaque jour existe avant qu'on y saute.
//    - Rejoindre une partie, ou la quitter sans en être l'hôte, ne produit
//      aucun événement temps réel (`reservation_participants` n'est pas
//      publiée, voir OpenGamesStore.swift) : la liste est relue explicitement
//      après chaque action.
//    - Attention : si le sport filtré n'a plus de partie à rejoindre alors
//      qu'un seul autre sport en a encore (ou aucun), l'en-tête disparaît avec
//      la pastille « Tous les sports » : la liste reste sur « Aucune partie
//      dans ce sport », sans moyen de retirer le filtre tant que l'écran n'est
//      pas recréé (voir `header`).
//    - Le détail ouvert depuis une notification lit la partie dans le magasin
//      (voir `detailDestination`), que `ensureLoaded` ne relit pas s'il est
//      déjà chargé.
//    - Textes : quelques messages tutoient (« Choisis-en un autre », « Ouvre la
//      tienne », et « Ta place sera libérée » dans la fenêtre de sortie, texte
//      d'OpenGame.swift), alors que le reste de l'écran vouvoie.
//    - Jours et dates calculés dans le fuseau de l'appareil, pas dans celui du
//      club.
//
//  Fil d'exécution
//    Vue SwiftUI sur l'acteur principal (réglage par défaut du projet). Les
//    appels réseau sont lancés dans des `Task` créées sur cet acteur : l'état
//    de l'écran y est modifié au retour.
//

import SwiftUI

/// Liste des parties ouvertes du club, racine de l'onglet « Parties ».
struct OpenGamesView: View {

    // MARK: - Environnement

    /// Session : compte connecté, enfant au nom de qui l'on agit, enfants gérés.
    @Environment(AuthController.self) private var auth
    /// Catalogue du club : terrains réservables et terrains fermés à la
    /// personne au nom de qui l'on agit.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation : la pile de l'onglet (`openGamesPath`) est poussée et vidée
    /// depuis cet écran.
    @Environment(AppRouter.self) private var router

    // MARK: - État de l'écran

    /// Magasin des parties, créé par cet écran et passé au formulaire
    /// d'ouverture : un seul magasin pour toute la pile de l'onglet.
    @State private var store = OpenGamesStore()
    /// Sport filtré par les pastilles, `nil` pour « Tous les sports ».
    @State private var sportFilter: Sport?

    /// Joueur dont la fiche est ouverte, en feuille. `nil` : aucune fiche.
    @State private var selectedPlayer: OpenGame.Player?
    /// Refus d'admission à expliquer, dans une fenêtre. `nil` : pas de fenêtre.
    @State private var refusal: OpenGameEligibility.Refusal?
    /// Partie et équipe en attente du choix de position (padel). Non nul, il
    /// ouvre la feuille de choix du côté.
    @State private var pendingSide: (game: OpenGame, team: Team?)?
    /// Vrai pendant l'appel à la base pour rejoindre ou quitter une partie :
    /// un voile et un indicateur d'attente couvrent l'écran.
    @State private var isJoining = false
    /// Message de la fenêtre « Action impossible » : refus de la base en
    /// rejoignant ou en quittant, ou sortie impossible pour un enfant. `nil` :
    /// pas de fenêtre.
    @State private var joinError: String?
    /// Partie dont la sortie attend confirmation : annulation si j'en suis
    /// l'hôte, simple départ sinon. Non nulle, elle ouvre la fenêtre de
    /// confirmation.
    @State private var pendingLeave: OpenGame?

    /// Le compte au nom duquel on agit : le sien, ou celui d'un enfant.
    private var profile: SessionProfile? { auth.activeProfile }

    // MARK: - Mesures du défilement

    /// Position du haut de chaque journée dans le repère de la liste,
    /// indexée par jour : la journée en surbrillance dans la bande est la
    /// dernière passée sous l'en-tête figé.
    @State private var sectionTops: [Date: CGFloat] = [:]
    /// Bas de l'en-tête figé (filtre et bande de jours), dans le même repère.
    @State private var headerBottom: CGFloat = 0
    /// Hauteur de l'en-tête figé.
    @State private var headerHeight: CGFloat = 0
    /// Jour touché dans la bande, tenu en surbrillance le temps du défilement
    /// qu'il déclenche : sans cela, la sélection passerait par tous les jours
    /// intermédiaires. Remis à `nil` quand le défilement s'arrête ou quand la
    /// personne reprend la main.
    @State private var pendingDay: Date?
    /// Le défilement vers `pendingDay` a déjà été recalé une fois.
    @State private var didAdjustPendingDay = false
    /// Hauteurs utiles pour que la dernière section puisse remonter jusqu'en
    /// haut : sans cela, toucher le dernier jour ne l'amènerait pas sous la
    /// bande, et la sélection retomberait sur la veille. Celle-ci : hauteur
    /// visible de la zone de défilement, marges du haut et du bas retirées.
    @State private var viewportHeight: CGFloat = 0
    /// Hauteur totale de la zone de défilement, barres comprises : c'est le
    /// repère des ancres de `scrollTo`.
    @State private var containerHeight: CGFloat = 0
    /// Hauteur de la dernière journée de la liste, mesurée à l'affichage.
    @State private var lastSectionHeight: CGFloat = 0
    /// Cartes dépliées. Toutes repliées par défaut : la liste se parcourt
    /// d'un coup d'œil.
    @State private var expandedGames: Set<UUID> = []

    // MARK: - Lectures dérivées

    /// Parties à rejoindre du sport filtré, sans celles qui se jouent sur un
    /// terrain fermé à la personne au nom de qui l'on agit, sauf si le compte
    /// connecté ou l'un des enfants qu'il gère y joue déjà : il doit pouvoir la
    /// retrouver et la quitter.
    private var visibleGames: [OpenGame] {
        // Profils « à moi » : le compte connecté et tous ses enfants gérés.
        let mine = Set([auth.sessionProfile?.id].compactMap { $0} + auth.managedChildren.map(\.profileId))
        return store.openForJoining(sport: sportFilter).filter { game in
            // Terrain inconnu, ou ouvert à la personne : la partie reste.
            guard let courtId = game.courtId, catalog.isForbidden(courtId) else { return true }
            // Terrain fermé : seulement si l'un des miens y joue.
            return game.players.contains { mine.contains($0.profileId) }
        }
    }

    /// Parties visibles regroupées par jour (début de journée, calendrier de
    /// l'appareil) : jours dans l'ordre chronologique, parties triées par heure
    /// de début.
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleGames) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            DaySection(day: day, games: grouped[day, default: []].sorted { $0.startsAt < $1.startsAt })
        }
    }

    // MARK: - Corps

    /// Liste défilante dont l'en-tête épinglé porte le filtre de sport et la
    /// bande de jours, barre « Ouvrir une partie » en bas, puis les
    /// destinations de navigation, les feuilles et les fenêtres de l'onglet.
    var body: some View {
        // Calculées une fois par rendu, puis passées à l'en-tête et au contenu.
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
            // Hauteur visible de la liste, marges retirées : sert à l'espace
            // laissé sous la dernière journée.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            } action: { _, height in
                viewportHeight = height
            }
            // Hauteur totale de la zone de défilement : repère des ancres de
            // `scrollTo` (voir `dayAnchorPoint`).
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                containerHeight = height
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    // Reprise en main : la position réelle reprend la main.
                    pendingDay = nil
                case .idle:
                    // Au premier saut depuis le haut, le grand titre se replie
                    // pendant le défilement et la bande remonte : on recale
                    // une fois, avec sa position définitive, pour que
                    // l'étiquette du jour tombe pile sous la bande.
                    if let day = pendingDay, !didAdjustPendingDay {
                        didAdjustPendingDay = true
                        withAnimation(.smooth(duration: 0.2)) {
                            proxy.scrollTo(DayAnchor(day: day), anchor: dayAnchorPoint)
                        }
                    } else {
                        // Défilement terminé, déjà recalé ou sans jour en
                        // attente : la surbrillance suit de nouveau la
                        // position réelle.
                        pendingDay = nil
                    }
                default:
                    break
                }
            }
            // Un autre sport n'a pas forcément de partie le jour affiché : on
            // repart du premier jour.
            .onChange(of: sportFilter) { _, _ in
                sectionTops = [:]
                pendingDay = nil
                if let first = daySections.first?.day {
                    proxy.scrollTo(DayAnchor(day: first), anchor: dayAnchorPoint)
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
        // Les quatre étapes du tunnel d'ouverture (sport, créneau, terrain,
        // réglages) sont déclarées à la racine : le magasin reste un objet
        // unique, partagé par tous les écrans.
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
        // Partie créée : écran de succès propre à l'ouverture.
        .navigationDestination(for: OpenGameConfirmation.self) { confirmation in
            OpenGameConfirmedView(confirmation: confirmation)
        }
        // Partie rejointe : le même écran de succès qu'après une réservation,
        // avec son titre (« Vous avez rejoint la partie », ou « Prénom a
        // rejoint la partie » pour un enfant) et un bouton qui ramène à la
        // liste en vidant la pile. Cet écran masque le bouton retour et
        // propose l'activation des notifications de parties.
        .navigationDestination(for: OpenGameJoinedConfirmation.self) { joined in
            BookingConfirmedView(
                confirmation: joined.booking,
                title: joined.title,
                doneTitle: "Voir les parties ouvertes",
                doneSymbol: "list.bullet"
            ) {
                router.openGamesPath = NavigationPath()
            }
        }
        // Ouverte depuis une notification : la partie annoncée, directement.
        .navigationDestination(for: OpenGameDetailRoute.self) { route in
            detailDestination(route)
        }
        // Chargement des parties, puis écoute du temps réel jusqu'à
        // l'annulation de la tâche : disparition de l'écran, ou changement de
        // club, qui la relance.
        .task(id: profile?.clubId) {
            guard let clubId = profile?.clubId else { return }
            await store.activate(clubId: clubId)
        }
        // Terrains fermés relus à chaque affichage de la liste.
        .task { await refreshCourtAccess() }
        // Tirer pour actualiser : terrains fermés, puis parties et fiches des
        // joueurs.
        .refreshable {
            await refreshCourtAccess()
            await store.reload()
        }
        // Fiche du joueur touché sur une carte, avec ce que le magasin sait
        // de lui (`roster`).
        .sheet(item: $selectedPlayer) { player in
            PlayerProfileSheet(player: player, info: store.roster[player.profileId])
        }
        // Padel : choix du côté avant de rejoindre ; choisir lance l'adhésion.
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
        // Refus d'admission expliqué avant tout envoi (`attemptJoin`).
        .alert(refusal?.title ?? "", isPresented: refusalBinding) {
            Button("J'ai compris") { refusal = nil }
        } message: {
            Text(refusal?.message ?? "")
        }
        // Confirmation de sortie : « Annuler la partie » pour l'hôte,
        // « Quitter la partie » pour un joueur ; « Conserver » ne fait rien.
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
        // Échec en rejoignant ou en quittant : message de la base, tel quel.
        .alert("Action impossible", isPresented: joinErrorBinding) {
            Button("OK") { joinError = nil }
        } message: {
            Text(joinError ?? "")
        }
        // Voile léger et indicateur d'attente pendant l'appel à la base.
        .overlay {
            if isJoining {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .overlay { ProgressView() }
            }
        }
        // Le changement de sport filtré s'anime.
        .animation(.smooth(duration: 0.3), value: sportFilter)
    }

    /// Quatrième étape du tunnel d'ouverture : le formulaire de réglages.
    ///
    /// Le terrain est relu dans le catalogue à l'affichage : s'il a été
    /// désactivé pendant que le membre réglait sa partie, on le dit plutôt que
    /// d'ouvrir un formulaire qui échouera.
    ///
    /// - Parameter route: sport, jour, créneau et terrain choisis aux étapes
    ///   précédentes.
    /// - Returns: le formulaire, ou un message « Terrain indisponible » si le
    ///   terrain n'est plus parmi les terrains réservables du sport (désactivé,
    ///   ou fermé à la personne).
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

    /// En-tête épinglé en haut de la liste : pastilles de sport, puis bande de
    /// jours.
    ///
    /// Absent quand il n'y a ni partie à parcourir ni sport à choisir.
    /// Attention : la condition porte sur les journées du sport filtré. Si ce
    /// sport n'a plus de partie à rejoindre alors qu'un seul autre sport en a
    /// encore (ou aucun), l'en-tête disparaît avec la pastille « Tous les
    /// sports », et le filtre ne peut plus être retiré.
    ///
    /// - Parameters:
    ///   - sections: journées affichées, déjà filtrées par sport.
    ///   - proxy: lecteur de défilement, pour sauter à un jour.
    /// - Returns: l'en-tête, ou rien.
    @ViewBuilder
    private func header(_ sections: [DaySection], proxy: ScrollViewProxy) -> some View {
        // Jours qui ont au moins une partie : les seuls que la bande laisse
        // toucher.
        let gameDays = Set(sections.map(\.day))

        // Des parties à parcourir, ou plusieurs sports entre lesquels choisir.
        if !sections.isEmpty || store.sportsWithGames.count > 1 {
            VStack(spacing: 10) {
                sportFilterBar

                // Bande de jours, seulement quand la liste a des journées.
                if !sections.isEmpty {
                    // Tous sports confondus, le jour choisi prend l'aplat bleu
                    // marine, très clair en mode sombre : son texte prend
                    // `textOnInverse` (blanc en clair, sombre en sombre). Un sport
                    // filtré garde son accent et le texte blanc.
                    DayStrip(
                        days: stripDays(sections),
                        accent: sportFilter?.accent ?? Brand.navy700,
                        selectedForeground: sportFilter == nil ? Brand.textOnInverse : .white,
                        selection: daySelection(sections, proxy: proxy),
                        isEnabled: { gameDays.contains($0) }
                    )
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            // Fond opaque : les cartes passent dessous au défilement.
            .background(Brand.background)
            // Bas et hauteur de l'en-tête dans le repère du défilement : le
            // jour en surbrillance et le point d'arrivée d'un saut en dépendent.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                headerBottom = frame.maxY
                headerHeight = frame.height
            }
        }
    }

    /// Une semaine au moins à partir d'aujourd'hui, prolongée jusqu'au
    /// dernier jour qui a une partie.
    ///
    /// - Parameter sections: journées affichées, dans l'ordre chronologique.
    /// - Returns: les jours de la bande, chacun au début de sa journée
    ///   (aujourd'hui et les six jours suivants au minimum).
    private func stripDays(_ sections: [DaySection]) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let lastDay = sections.last?.day ?? today
        // Six jours après aujourd'hui au moins : la bande montre toujours une
        // semaine entière.
        let span = max(6, calendar.dateComponents([.day], from: today, to: lastDay).day ?? 0)
        return DayStrip.days(horizonJours: span, from: today)
    }

    /// Toucher un jour fait défiler la liste jusqu'à lui ; défiler la liste
    /// met à jour le jour en surbrillance.
    ///
    /// - Parameters:
    ///   - sections: journées affichées.
    ///   - proxy: lecteur de défilement.
    /// - Returns: la liaison donnée à la bande de jours.
    private func daySelection(_ sections: [DaySection], proxy: ScrollViewProxy) -> Binding<Date> {
        Binding(
            // Jour en surbrillance : celui que la liste montre (voir
            // `currentDay`), ou aujourd'hui s'il n'y a aucune journée.
            get: { currentDay(sections) ?? Calendar.current.startOfDay(for: .now) },
            // Jour touché : tenu en surbrillance pendant le saut, qui sera
            // recalé une fois à l'arrêt du défilement.
            set: { day in
                pendingDay = day
                didAdjustPendingDay = false
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(DayAnchor(day: day), anchor: dayAnchorPoint)
                }
            }
        )
    }

    /// Où poser le début d'une journée : juste sous la bande de jours épinglée,
    /// avec un peu d'air, pour que son étiquette et ses premières parties
    /// soient visibles en entier. Exprimé en fraction de la hauteur de la zone
    /// de défilement, comme l'attend `scrollTo`.
    private var dayAnchorPoint: UnitPoint {
        // Zone pas encore mesurée : le haut.
        guard containerHeight > 0 else { return .top }
        // Dix points sous l'en-tête, ramenés entre 0 et 1.
        let y = min(max((headerBottom + 10) / containerHeight, 0), 1)
        return UnitPoint(x: 0.5, y: y)
    }

    /// Dernière journée dont le haut est passé sous l'en-tête figé.
    ///
    /// - Parameter sections: journées affichées.
    /// - Returns: le jour touché dans la bande tant que son défilement dure ;
    ///   sinon la dernière journée passée sous l'en-tête, ou la première
    ///   journée ; `nil` seulement sans journée.
    private func currentDay(_ sections: [DaySection]) -> Date? {
        if let pendingDay { return pendingDay }
        // Un peu de marge : la journée posée par la bande arrive à 10 points
        // sous l'en-tête, et doit compter comme affichée.
        let threshold = headerBottom + 16
        // Une journée pas encore mesurée compte comme hors de vue.
        return sections.last { (sectionTops[$0.day] ?? .infinity) <= threshold }?.day
            ?? sections.first?.day
    }

    // MARK: - Filtres

    /// Pastilles de sport : « Tous les sports », puis une pastille par sport
    /// qui a au moins une partie à rejoindre (`OpenGamesStore.sportsWithGames`).
    /// Ce décompte inclut les parties masquées parce que leur terrain est
    /// fermé à la personne : une pastille peut donc mener à une liste vide.
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

    /// Une pastille du filtre de sport.
    ///
    /// - Parameters:
    ///   - title: libellé (« Tous les sports » ou le nom du sport).
    ///   - sport: sport filtré par la pastille, `nil` pour tous.
    ///   - tint: couleur de la pastille (accent du sport, bleu marine pour tous).
    /// - Returns: un bouton qui choisit ce filtre ; sans effet s'il l'est déjà.
    private func filterChip(title: String, sport: Sport?, tint: Color) -> some View {
        let isSelected = sportFilter == sport

        return Button {
            // Déjà choisie : ni changement, ni retour haptique.
            guard !isSelected else { return }
            sportFilter = sport
            Haptics.selection()
        } label: {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                // Pastille choisie : texte blanc sur l'accent d'un sport, mais
                // `textOnInverse` sur le bleu marine de « Tous les sports »,
                // très clair en mode sombre (voir BrandPalette).
                .foregroundStyle(isSelected ? (sport == nil ? Brand.textOnInverse : Color.white) : tint)
                // Aplat plein si choisie, teinte légère (12 %) sinon.
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? tint : tint.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        // VoiceOver annonce la pastille choisie.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Contenu

    /// Corps de la liste selon l'état du magasin.
    ///
    /// - Parameter sections: journées à afficher.
    /// - Returns: l'erreur de lecture, des cartes fantômes pendant le premier
    ///   chargement, l'état vide, ou les journées suivies d'un espace final.
    @ViewBuilder
    private func content(_ sections: [DaySection]) -> some View {
        if case .failed(let message) = store.phase {
            // Lecture impossible alors que rien n'était encore affiché (le
            // magasin garde une liste déjà chargée en cas d'échec ultérieur).
            errorState(message)
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty, store.phase != .ready {
            // Premier chargement : trois cartes fantômes.
            skeletons
                .padding(.horizontal, 20)
        } else if visibleGames.isEmpty {
            // Chargé, mais aucune partie à rejoindre (dans ce sport).
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

    /// Une journée : son séparateur, puis ses parties, repliées ou dépliées.
    ///
    /// - Parameters:
    ///   - section: la journée et ses parties.
    ///   - isLast: dernière journée de la liste, dont la hauteur est mesurée.
    /// - Returns: le bloc de la journée, avec son ancre de défilement.
    private func daySection(_ section: DaySection, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DayHeader(day: section.day)
            ForEach(section.games) { game in
                // Un tap sur la carte la déplie, ou la replie si elle l'était.
                card(for: game, isExpanded: expandedGames.contains(game.id)) {
                    withAnimation(.smooth(duration: 0.3)) {
                        if expandedGames.remove(game.id) == nil { expandedGames.insert(game.id) }
                    }
                    Haptics.selection()
                }
            }
        }
        // Cible du défilement : un point au tout début de la journée, juste
        // au-dessus de son étiquette « Samedi 31 octobre ».
        .background(alignment: .top) {
            Color.clear
                .frame(height: 1)
                .id(DayAnchor(day: section.day))
                .allowsHitTesting(false)
        }
        // Haut de la journée dans le repère du défilement (jour en
        // surbrillance), et hauteur de la dernière (espace final).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            sectionTops[section.day] = frame.minY
            if isLast { lastSectionHeight = frame.height }
        }
    }

    /// Carte d'une partie, branchée sur les actions de l'écran.
    ///
    /// - Parameters:
    ///   - game: partie affichée.
    ///   - isExpanded: version complète ou résumé ; dépliée par défaut, comme
    ///     sur le détail ouvert depuis une notification.
    ///   - onToggleExpanded: bascule dépliée ou repliée ; `nil` (détail) : la
    ///     carte ne se replie pas.
    /// - Returns: la carte. Le rôle (hôte, joueur, extérieur) est calculé pour
    ///   la personne au nom de qui l'on agit.
    private func card(
        for game: OpenGame,
        isExpanded: Bool = true,
        onToggleExpanded: (() -> Void)? = nil
    ) -> some View {
        OpenGameCard(
            game: game,
            roster: store.roster,
            myProfileId: profile?.id,
            // Joueur touché : sa fiche, en feuille.
            onSelectPlayer: { selectedPlayer = $0 },
            // Place libre touchée : rejoindre l'équipe de cette place.
            onSelectFreeSlot: { team in attemptJoin(game, team: team) },
            // Bouton « Rejoindre » : la première équipe qui a de la place.
            onJoin: { attemptJoin(game, team: game.firstTeamWithRoom) },
            // « Quitter » ou « Annuler la partie » : confirmation d'abord.
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
    ///
    /// Limite connue : `ensureLoaded` ne relit rien si le magasin a déjà été
    /// chargé. Le détail s'appuie alors sur la dernière lecture, que le temps
    /// réel ne tient à jour que tant que la tâche de la liste (`activate`)
    /// tourne : une partie créée pendant que cette tâche ne tournait pas peut
    /// manquer, et l'écran afficher « Partie plus proposée » jusqu'à la
    /// prochaine relecture.
    ///
    /// - Parameter route: partie annoncée (`reservations.id`).
    /// - Returns: la carte dépliée, précédée d'un message si elle n'est plus
    ///   ouverte ; « Partie plus proposée » si elle n'est pas dans le magasin
    ///   une fois chargé ; l'erreur de lecture ; ou une carte fantôme pendant
    ///   le chargement.
    @ViewBuilder
    private func detailDestination(_ route: OpenGameDetailRoute) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if let game = store.game(id: route.gameId) {
                    // Partie trouvée : son état si elle n'est plus ouverte,
                    // puis la carte complète.
                    if let status = unavailableStatus(of: game) {
                        InlineMessage(kind: .info, message: status)
                    }
                    card(for: game)
                } else if store.phase == .ready {
                    // Magasin chargé sans elle : il ne garde que les parties
                    // confirmées, du jour et à venir. Elle a donc été annulée
                    // ou elle est passée (voir la limite ci-dessus).
                    PhasePlaceholder(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "Partie plus proposée",
                        message: "Elle a été annulée ou a déjà eu lieu. D'autres parties vous attendent peut-être.",
                        accent: Brand.warning
                    )
                    // Retour à la liste : la pile de l'onglet est vidée.
                    Button("Voir les parties ouvertes") {
                        router.openGamesPath = NavigationPath()
                    }
                    .buttonStyle(.glass)
                } else if case .failed(let message) = store.phase {
                    // Lecture impossible.
                    errorState(message)
                } else {
                    // Chargement en cours.
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

    /// Pourquoi la partie du détail ne peut plus être rejointe.
    ///
    /// - Parameter game: partie affichée.
    /// - Returns: le message à afficher au-dessus de la carte, ou `nil` si elle
    ///   est encore ouverte ou si la personne y joue déjà.
    private func unavailableStatus(of game: OpenGame) -> String? {
        // J'y suis déjà : la carte montre elle-même mon rôle.
        if let myId = profile?.id, game.contains(myId) { return nil }
        // Le magasin ne lit que des parties confirmées : une partie annulée
        // n'y figure pas, et c'est « Partie plus proposée » qui s'affiche. Ce
        // cas ne se présente donc pas avec les lectures actuelles.
        if game.isCancelled { return "Cette partie a été annulée." }
        if game.hasStarted { return "Cette partie a déjà commencé." }
        if game.isFull { return "Cette partie vient d'être complétée." }
        return nil
    }

    /// Trois cartes fantômes, pendant le premier chargement.
    private var skeletons: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonBlock(height: 230, cornerRadius: Radius.card)
            }
        }
    }

    /// Aucune partie à rejoindre, dans tous les sports ou dans le sport filtré.
    ///
    /// Le message invite à ouvrir une partie, même quand on agit pour un
    /// enfant et que la barre « Ouvrir une partie » est masquée.
    private var emptyState: some View {
        PhasePlaceholder(
            systemImage: "figure.tennis.circle",
            title: sportFilter == nil ? "Aucune partie ouverte" : "Aucune partie dans ce sport",
            message: "Ouvre la tienne : réserve un créneau et laisse les places libres aux autres membres.",
            accent: Brand.pine800
        )
    }

    /// Lecture des parties impossible, avec un bouton pour réessayer.
    ///
    /// - Parameter message: description de l'erreur rendue par le magasin.
    /// - Returns: une carte « Parties indisponibles ».
    private func errorState(_ message: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Parties indisponibles")
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                // Nouvelle lecture des parties et des fiches des joueurs.
                Button("Réessayer") {
                    Task { await store.reload() }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Ouvrir une partie

    /// Barre du bas « Ouvrir une partie » : pousse la première étape du
    /// tunnel, le choix du sport. Masquée quand on agit pour un enfant (voir
    /// `body`).
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
    ///
    /// - Parameters:
    ///   - game: partie visée.
    ///   - team: équipe visée en double (celle de la place libre touchée, ou la
    ///     première qui a de la place) ; `nil` en simple.
    private func attemptJoin(_ game: OpenGame, team: Team?) {
        guard let profile else { return }

        // Une partie par jour (les autres parties du même jour, celle-ci
        // exclue), mixité, niveau : le premier refus trouvé est expliqué.
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

    /// Écran de succès après avoir rejoint une partie, comme après une
    /// réservation : `BookingConfirmedView`, avec son propre titre, qui propose
    /// aussi d'activer les notifications de parties.
    ///
    /// Limite connue : si la relecture du magasin a échoué, la partie lue est
    /// l'ancienne. Le nombre de joueurs compte bien le nouveau venu, mais la
    /// liste des noms (texte partagé, note du calendrier) ne le contient pas.
    /// Le texte partagé, propre à `BookingConfirmedView`, commence aussi par
    /// « Réservation confirmée ! ».
    ///
    /// - Parameter game: partie rejointe, telle qu'affichée avant l'adhésion.
    private func showJoinedConfirmation(for game: OpenGame) {
        // La partie relue après l'adhésion, avec le nouveau venu ; à défaut,
        // celle d'avant.
        let updated = store.game(id: game.id) ?? game
        let names = updated.players.map(\.displayName)
        router.openGamesPath.append(OpenGameJoinedConfirmation(
            booking: BookingConfirmation(
                // Une partie ouverte est une réservation : même identifiant.
                reservationId: game.id,
                courtName: game.courtName,
                clubName: auth.sessionProfile?.clubName ?? "",
                date: game.date,
                slot: game.slot,
                // Au moins un joueur de plus qu'avant : la relecture a pu échouer.
                playerCount: max(updated.players.count, game.players.count + 1),
                // Rejoindre n'enregistre aucun paiement (`join_open_game`
                // inscrit le joueur sans supplément) : la pastille affiche
                // « Confirmée ».
                isPaid: false,
                participantNames: names
            ),
            // Le parent a inscrit son enfant : « Prénom a rejoint la partie ».
            childName: auth.isActingForChild ? (profile?.prenom ?? profile?.displayName) : nil
        ))
    }

    /// Rejoint la partie au nom de la personne au nom de qui l'on agit, puis
    /// pousse l'écran de succès. En cas d'échec, le message de la base
    /// s'affiche et la liste est relue.
    ///
    /// À noter : les rappels reprogrammés sont ceux du compte connecté
    /// (réservations qu'il a créées ou auxquelles il participe) ; une partie
    /// rejointe pour un enfant n'en fait pas partie si le parent ne l'a pas
    /// créée et n'y joue pas.
    ///
    /// - Parameters:
    ///   - game: partie visée.
    ///   - team: équipe visée en double, `nil` en simple (ignorée par le
    ///     service hors double).
    ///   - side: côté choisi au padel, « indifferent » ailleurs.
    private func join(_ game: OpenGame, team: Team?, side: Side) {
        // Ferme la feuille de choix du côté, et couvre l'écran.
        pendingSide = nil
        isJoining = true

        Task {
            do {
                // Fonction SQL `join_open_game` ; pour un enfant, son profil
                // est transmis et la base vérifie le droit du parent.
                try await OpenGameService.join(
                    game: game, team: team, side: side,
                    forChild: auth.isActingForChild ? profile?.id : nil
                )
                Haptics.success()
                // Rappels locaux du compte connecté, reprogrammés à part, sans
                // attendre.
                if let me = auth.sessionProfile { Task { await BookingReminders.refresh(for: me) } }
                // Relecture avant l'écran de succès, pour qu'il compte et
                // nomme le nouveau venu.
                await store.reload()
                showJoinedConfirmation(for: game)
            } catch {
                // La base refait tous les contrôles sous verrou : ce chemin est
                // celui de la concurrence, et son message est déjà rédigé.
                joinError = error.localizedDescription
                Haptics.failure()
                // Refus sur un terrain fermé : on relit les fermetures pour que
                // la partie disparaisse de la liste.
                await refreshCourtAccess()
                await store.reload()
            }
            isJoining = false
        }
    }

    /// Relit les terrains fermés pour la personne au nom de qui l'on agit :
    /// l'enfant choisi, ou le compte connecté.
    private func refreshCourtAccess() async {
        await catalog.refreshAccess(childId: auth.isActingForChild ? profile?.id : nil)
    }

    // MARK: - Quitter / Annuler

    /// Titre de la fenêtre de sortie : « Annuler cette partie ? » pour l'hôte,
    /// « Quitter cette partie ? » pour un joueur ; vide sans partie en attente.
    private var leaveTitle: String {
        guard let pendingLeave else { return "" }
        return pendingLeave.role(for: profile?.id) == .host
            ? pendingLeave.cancelConfirmationTitle
            : pendingLeave.leaveConfirmationTitle
    }

    /// L'hôte est averti du nombre de joueurs qu'il retire ; un simple joueur
    /// est rassuré : la partie ne disparaît pas derrière lui.
    ///
    /// - Parameter game: partie à quitter.
    /// - Returns: une ligne « terrain · date · horaire », puis la conséquence.
    private func leaveMessage(for game: OpenGame) -> String {
        let context = "\(game.courtName) · \(game.date.longFrenchDate) · \(game.slot.label)"
        let consequence = game.role(for: profile?.id) == .host
            ? game.hostCancellationMessage
            : game.playerLeaveMessage
        return "\(context)\n\(consequence)"
    }

    /// Quitte la partie, ou l'annule si l'on en est l'hôte, puis relit la
    /// liste. Refusé quand on agit pour un enfant.
    ///
    /// - Parameter game: partie confirmée dans la fenêtre de sortie.
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
                // Le service retire aussi le rappel local de la partie.
                try await OpenGameService.leave(gameId: game.id)
                Haptics.destructive()
            } catch {
                joinError = error.localizedDescription
                Haptics.failure()
            }
            // Relecture dans tous les cas : le départ d'un joueur ne produit
            // pas d'événement temps réel (voir l'en-tête), seule l'annulation
            // par l'hôte en produit un.
            await store.reload()
            isJoining = false
        }
    }

    // MARK: - Liaisons de présentation

    /// Fenêtre de refus ouverte tant qu'un refus est posé ; la fermer l'efface.
    private var refusalBinding: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    /// Fenêtre « Action impossible » ouverte tant qu'un message est posé.
    private var joinErrorBinding: Binding<Bool> {
        Binding(get: { joinError != nil }, set: { if !$0 { joinError = nil } })
    }

    /// Feuille de choix du côté ouverte tant qu'une partie attend ce choix.
    private var sidePickerBinding: Binding<Bool> {
        Binding(get: { pendingSide != nil }, set: { if !$0 { pendingSide = nil } })
    }

    /// Fenêtre de sortie ouverte tant qu'une partie attend confirmation.
    private var leaveConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } })
    }
}

// MARK: - Types de la liste

/// Identifiant de défilement d'une journée, distinct de la date seule pour ne
/// pas se confondre avec d'autres vues identifiées par une date.
private struct DayAnchor: Hashable {
    /// Jour visé, au début de sa journée.
    let day: Date
}

/// Les parties d'une même journée.
private struct DaySection: Identifiable {
    /// Jour, au début de sa journée (calendrier de l'appareil).
    let day: Date
    /// Parties du jour, triées par heure de début.
    let games: [OpenGame]
    /// Le jour sert d'identifiant : une seule section par jour.
    var id: Date { day }
}

/// Séparateur de jour : « Aujourd'hui », « Demain », « Samedi 24 octobre ».
///
/// Pastille inversée : aplat de la couleur du texte principal (sombre en mode
/// clair, presque blanc en mode sombre) et texte `textOnInverse` (blanc en mode
/// clair, sombre en mode sombre). Un texte blanc fixe y était illisible en mode
/// sombre, blanc sur blanc (fiche D13).
private struct DayHeader: View {
    /// Jour annoncé.
    let day: Date

    /// Pastille avec l'icône du calendrier, lue comme un titre par VoiceOver.
    var body: some View {
        Label(day.relativeFrenchDayTitle, systemImage: "calendar")
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(Brand.textOnInverse)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Brand.textPrimary, in: .capsule)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `sheet(item:)` pour un modèle `Identifiable` optionnel, réécrit sur
/// `sheet(isPresented:)` : la feuille est ouverte tant que `item` a une valeur,
/// et sa fermeture remet `item` à `nil`.
///
/// Elle porte le nom de la version de SwiftUI (qui accepte en plus un
/// `onDismiss` facultatif) et, privée à ce fichier, c'est elle que le
/// compilateur retient pour `.sheet(item: $selectedPlayer)`. Différence de
/// comportement : si `item` change pendant que la feuille est ouverte, la
/// feuille reste ouverte et montre la nouvelle valeur, au lieu de se refermer
/// puis de se rouvrir. La raison de ce doublon n'est pas documentée.
private extension View {
    /// - Parameters:
    ///   - item: valeur présentée ; `nil` ferme la feuille.
    ///   - content: contenu de la feuille pour une valeur.
    /// - Returns: la vue munie de la feuille.
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
