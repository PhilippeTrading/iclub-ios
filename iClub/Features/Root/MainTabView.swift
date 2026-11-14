//
//  MainTabView.swift
//  iClub
//
//  Barre de navigation à 5 items. On s'appuie sur le `TabView` système : c'est
//  lui qui fournit le matériau Liquid Glass, la capsule derrière l'item actif
//  et l'effet de bord au défilement. Reproduire cela à la main donnerait un
//  résultat moins fidèle qu'Apple, pas plus.
//
//  Un re-tap sur l'onglet déjà actif revient à la racine de sa pile.
//
//  Par-dessus les onglets flotte la bulle de messagerie, qui ouvre la liste
//  des conversations en feuille.
//
//  Rôle
//    Coquille de l'application connectée, affichée par `RootView` dès que la
//    session est ouverte et le profil complet. Elle porte les cinq onglets
//    (Accueil, Réserver, Parties, Cours, Profil), chacun dans sa
//    `NavigationStack`, et lance les tâches de fond liées au compte.
//
//  Place dans l'application
//    - Accueil : `HomeView`, pile `AppRouter.homePath`.
//    - Réserver : `BookingView` (choix d'un créneau), pile
//      `AppRouter.bookingPath` ; l'historique « Mes réservations »
//      (`ReservationsView`) s'y pousse depuis le bouton en haut à droite.
//    - Parties : `OpenGamesView`, pile `AppRouter.openGamesPath`.
//    - Cours : `ActivitiesView`, pile `AppRouter.activitiesPath`.
//    - Profil : `ProfileView`, pile sans chemin partagé.
//    Chaque racine reçoit la barre du haut commune (`appTopBar()`, voir
//    AppTopBar.swift). La feuille de messagerie (`MessagesSheet`) et ses
//    erreurs sont pilotées par `MessagingCenter.shared`.
//
//  Tâches lancées à l'affichage (annulées quand la vue disparaît, par exemple
//  à la déconnexion)
//    - catalogue du club (terrains, horaires) chargé puis écouté en temps réel
//      (`ClubCatalog.activate`, table `courts`) ;
//    - groupes de messagerie de l'entraîneur, rappels d'appel de l'entraîneur
//      (`AttendanceReminders`), rappels de réservation du membre
//      (`BookingReminders`), puis écoute des messages (`MessagingCenter.activate`) ;
//    - terrains fermés à la personne au nom de qui l'on réserve
//      (`ClubCatalog.refreshAccess`, fonction SQL `terrains_interdits`) ;
//    - ouverture de l'écran visé par un tap sur une notification (rappel de
//      réservation, rappel d'appel, partie ouverte), y compris quand la
//      notification a lancé l'app à froid (`PushService.consumePending…`).
//
//  Effets de bord
//    Notifications locales reprogrammées sur l'appareil (rappels), lecture des
//    conversations, retours haptiques. Aucune écriture en base ici.
//
//  Fil d'exécution
//    Vue SwiftUI, sur l'acteur principal comme tout le projet.
//

import SwiftUI

// MARK: - Onglets

/// Les cinq onglets de l'application, dans l'ordre de la barre.
enum AppTab: Hashable, CaseIterable {
    /// « Accueil » : salutation, prochaine réservation, raccourcis par sport.
    case home
    /// « Réserver » : le tunnel de réservation d'un terrain (et non la liste
    /// de mes réservations, qui s'y pousse en historique).
    case reservations
    /// « Parties » : les parties ouvertes du club.
    case openGames
    /// « Cours » : cours, stages et activités du club.
    case activities
    /// « Profil » : informations personnelles, famille, documents, réglages.
    case profile
}

/// Clé de relecture des terrains fermés : le club, et la personne au nom de
/// qui l'on réserve.
///
/// Sert d'identifiant à un `.task(id:)` : la tâche est relancée dès que l'un
/// des deux change (connexion à un autre club, passage au compte d'un enfant).
private struct CourtAccessKey: Hashable {
    /// Club du compte connecté (`club_members.club_id`), `nil` avant la
    /// connexion.
    let clubId: UUID?
    /// Profil au nom duquel l'app agit : le compte connecté ou l'enfant
    /// sélectionné.
    let profileId: UUID?
}

/// Historique « Mes réservations », poussé sur la racine de l'onglet
/// « Réserver ».
///
/// Valeur de navigation sans donnée : le bouton horloge de la barre et
/// `AppRouter.openReservationHistory()` (tap sur un rappel de réservation)
/// la poussent dans `AppRouter.bookingPath`.
struct ReservationHistoryRoute: Hashable {}

// MARK: - Vue

/// Application connectée : la barre d'onglets, la bulle de messagerie et les
/// tâches de fond liées au compte.
struct MainTabView: View {
    /// Session : compte connecté, enfant sélectionné.
    @Environment(AuthController.self) private var auth
    /// Catalogue du club (terrains, horaires, terrains fermés).
    @Environment(ClubCatalog.self) private var catalog
    /// Onglet sélectionné et piles de navigation de chaque onglet.
    @Environment(AppRouter.self) private var router
    /// État global de la messagerie (bulle, feuille, non-lus, erreurs).
    @Environment(MessagingCenter.self) private var messaging

    /// Espace de noms de l'animation de zoom entre la bulle et la feuille de
    /// messagerie.
    @Namespace private var bubbleNamespace
    /// Premier plan ou arrière-plan de l'app : le retour au premier plan
    /// relance certaines relectures.
    @Environment(\.scenePhase) private var scenePhase

    /// Intercepte la sélection pour détecter le re-tap sur l'onglet courant.
    ///
    /// Toucher l'onglet déjà actif ramène sa pile à la racine ; toucher un autre
    /// onglet le sélectionne, avec un léger retour haptique.
    private var tabSelection: Binding<AppTab> {
        Binding {
            router.selectedTab
        } set: { newValue in
            if newValue == router.selectedTab {
                popToRoot(newValue)
            } else {
                Haptics.selection()
                router.selectedTab = newValue
            }
        }
    }

    /// Les cinq onglets, la bulle de messagerie, sa feuille et ses erreurs,
    /// puis les tâches de fond liées au compte.
    var body: some View {
        // Liaisons modifiables vers les piles du routeur et l'état de la
        // feuille de messagerie.
        @Bindable var router = router
        @Bindable var messaging = messaging

        return TabView(selection: tabSelection) {
            // Onglet Accueil.
            Tab("Accueil", systemImage: "house.fill", value: AppTab.home) {
                // Pile propre à l'accueil : la carte de prochaine réservation
                // ouvre le même détail que l'historique des réservations.
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .appTopBar()
                }
            }

            // La racine est la réservation d'un créneau ; l'historique est à un
            // tap, en haut à droite.
            Tab("Réserver", systemImage: "list.bullet.rectangle.portrait", value: AppTab.reservations) {
                NavigationStack(path: $router.bookingPath) {
                    BookingView()
                        .appTopBar()
                        .toolbar {
                            // Bouton horloge : pousse l'historique des réservations.
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink(value: ReservationHistoryRoute()) {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                                .accessibilityLabel("Historique")
                            }
                        }
                        .navigationDestination(for: ReservationHistoryRoute.self) { _ in
                            ReservationsView()
                        }
                }
            }

            // Item central : c'est le cœur de la nouveauté produit, il porte un
            // glyphe plein encapsulé là où les quatre autres sont des contours.
            Tab("Parties", systemImage: "figure.tennis.circle.fill", value: AppTab.openGames) {
                NavigationStack(path: $router.openGamesPath) {
                    OpenGamesView()
                        .appTopBar()
                }
            }

            // Onglet Cours : activités du club, et espace entraîneur.
            Tab("Cours", systemImage: "figure.run", value: AppTab.activities) {
                NavigationStack(path: $router.activitiesPath) {
                    ActivitiesView()
                        .appTopBar()
                }
            }

            // Onglet Profil : sa pile n'est pas portée par le routeur, aucun
            // écran extérieur n'a besoin d'y pousser quoi que ce soit.
            Tab("Profil", systemImage: "person.crop.circle.fill", value: AppTab.profile) {
                NavigationStack {
                    ProfileView()
                        .appTopBar()
                }
            }
        }
        .tint(Brand.navy700)
        // Bulle de messagerie flottante, en bas à droite.
        .overlay(alignment: .bottomTrailing) { messageBubble }
        // Feuille des conversations, ouverte par la bulle, par un bouton
        // « Écrire » ou par le tap sur une notification de message ; elle
        // s'ouvre en zoomant depuis la bulle.
        .sheet(isPresented: $messaging.isSheetPresented) {
            MessagesSheet()
                .navigationTransition(.zoom(sourceID: "message-bubble", in: bubbleNamespace))
        }
        // Erreur de messagerie (ouverture de conversation refusée, par
        // exemple), affichée par-dessus n'importe quel onglet.
        .alert("Messagerie", isPresented: messagingErrorBinding) {
            Button("OK") { messaging.errorMessage = nil }
        } message: {
            Text(messaging.errorMessage ?? "")
        }
        // Charge le catalogue du club dès que la session est connue, puis reste
        // à l'écoute des modifications faites par l'admin (Realtime).
        // `activate` ne rend la main qu'à l'annulation de la tâche.
        .task(id: auth.sessionProfile?.clubId) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await catalog.activate(clubId: clubId)
        }
        // Conversations et non-lus, tenus à jour en temps réel.
        // L'ordre compte : `messaging.activate()` reste à l'écoute jusqu'à
        // l'annulation de la tâche, les autres étapes passent donc avant.
        .task(id: auth.sessionProfile?.id) {
            guard let profile = auth.sessionProfile else { return }
            // Les groupes de cours de l'entraîneur, créés ou complétés avant
            // de charger la liste.
            await messaging.syncCoachGroups(for: profile)
            // Un rappel « faire l'appel » au début de chaque séance à venir.
            await AttendanceReminders.refresh(for: profile)
            // Et, pour chaque membre, un rappel une heure avant ses réservations.
            await BookingReminders.refresh(for: profile)
            await messaging.activate()
        }
        // Retour de l'app au premier plan. Une réservation prise sur le web
        // doit aussi avoir son rappel : on refait la liste à chaque retour dans
        // l'app. Les terrains fermés, qui n'ont pas de temps réel, sont relus
        // au même moment.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let profile = auth.sessionProfile else { return }
            Task {
                await BookingReminders.refresh(for: profile)
                await refreshCourtAccess()
            }
        }
        // Terrains fermés : pour soi, ou pour l'enfant sélectionné en haut.
        .task(id: CourtAccessKey(clubId: auth.sessionProfile?.clubId, profileId: auth.activeProfile?.id)) {
            await refreshCourtAccess()
        }
        // Tap sur un rappel de réservation : l'historique des réservations.
        // D'abord le tap mémorisé avant l'affichage (lancement à froid), puis
        // chaque tap suivant, signalé par `PushService`.
        .task {
            if PushService.consumePendingBookingReminder() { router.openReservationHistory() }
            for await _ in NotificationCenter.default.notifications(named: PushService.bookingReminderRequested) {
                if PushService.consumePendingBookingReminder() { router.openReservationHistory() }
            }
        }
        // Tap sur le rappel d'appel : l'écran d'appel de la séance, directement.
        .task {
            if let sessionId = PushService.consumePendingAttendance() { openAttendance(sessionId) }
            for await _ in NotificationCenter.default.notifications(named: PushService.attendanceRequested) {
                if let sessionId = PushService.consumePendingAttendance() { openAttendance(sessionId) }
            }
        }
        // Tap sur une notification de partie : on ouvre directement la partie,
        // y compris quand la notification a lancé l'app à froid.
        .task {
            if let gameId = PushService.consumePendingGame() { openGame(gameId) }
            for await _ in NotificationCenter.default.notifications(named: PushService.openGameRequested) {
                if let gameId = PushService.consumePendingGame() { openGame(gameId) }
            }
        }
    }

    // MARK: - Bulle de messagerie

    /// Ronde, en verre, au-dessus de la barre d'onglets. Elle porte le total
    /// des non-lus et s'efface sur les écrans dont l'action principale est en
    /// bas, pour ne jamais la masquer.
    ///
    /// Les écrans concernés le signalent par `hidesMessageBubble()` ; le total
    /// des non-lus est celui compté par la base (`MessagingCenter.totalUnread`).
    @ViewBuilder
    private var messageBubble: some View {
        // Bulle masquée tant qu'un écran à bouton d'action en bas est affiché.
        if !messaging.isBubbleHidden {
            Button {
                Haptics.tap()
                messaging.present()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Brand.navy700)
                    .frame(width: 54, height: 54)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay(alignment: .topTrailing) {
                        // Pastille rouge des non-lus, plafonnée à « 99+ ».
                        if messaging.totalUnread > 0 {
                            Text(messaging.totalUnread > 99 ? "99+" : "\(messaging.totalUnread)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Brand.error, in: .capsule)
                                .offset(x: 4, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain)
            // Point de départ de l'animation de zoom vers la feuille.
            .matchedTransitionSource(id: "message-bubble", in: bubbleNamespace)
            .accessibilityLabel(bubbleAccessibilityLabel)
            .padding(.trailing, 20)
            // Au-dessus de la barre d'onglets flottante.
            .padding(.bottom, 92)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Libellé VoiceOver de la bulle, avec le nombre de messages non lus
    /// accordé au singulier ou au pluriel.
    private var bubbleAccessibilityLabel: String {
        switch messaging.totalUnread {
        case 0: "Messages"
        case 1: "Messages, 1 non lu"
        case let count: "Messages, \(count) non lus"
        }
    }

    /// Liaison de l'alerte de messagerie : vraie tant qu'un message d'erreur
    /// est posé ; la refermer efface ce message.
    private var messagingErrorBinding: Binding<Bool> {
        Binding(
            get: { messaging.errorMessage != nil },
            set: { if !$0 { messaging.errorMessage = nil } }
        )
    }

    /// Relit les terrains fermés (fonction SQL `terrains_interdits`) pour la
    /// personne au nom de qui l'on réserve : l'enfant sélectionné, ou
    /// soi-même (`childId` à `nil`).
    private func refreshCourtAccess() async {
        await catalog.refreshAccess(childId: auth.isActingForChild ? auth.activeProfile?.id : nil)
    }

    // MARK: - Navigation

    /// Ouvre l'écran d'appel d'une séance dans l'onglet Cours, à la place de
    /// tout ce qui y était empilé.
    ///
    /// - Parameter sessionId: séance (`activite_seances.id`) portée par le
    ///   rappel d'appel touché.
    private func openAttendance(_ sessionId: UUID) {
        var path = NavigationPath()
        path.append(AttendanceRoute(sessionId: sessionId))
        router.activitiesPath = path
        router.selectedTab = .activities
    }

    /// Ouvre le détail d'une partie ouverte dans l'onglet Parties, à la place
    /// de tout ce qui y était empilé.
    ///
    /// - Parameter gameId: réservation de la partie (`reservations.id`), lue
    ///   dans la notification touchée.
    private func openGame(_ gameId: UUID) {
        var path = NavigationPath()
        path.append(OpenGameDetailRoute(gameId: gameId))
        router.openGamesPath = path
        router.selectedTab = .openGames
    }

    /// Ramène la pile d'un onglet à sa racine, avec animation. Sans effet si
    /// la pile est déjà vide, et pour l'onglet Profil, dont la pile n'est pas
    /// portée par le routeur.
    ///
    /// - Parameter tab: onglet touché alors qu'il était déjà actif.
    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .activities:
            guard !router.activitiesPath.isEmpty else { return }
            withAnimation(.smooth) { router.activitiesPath = NavigationPath() }
        case .reservations:
            guard !router.bookingPath.isEmpty else { return }
            withAnimation(.smooth) { router.bookingPath = NavigationPath() }
        case .openGames:
            guard !router.openGamesPath.isEmpty else { return }
            withAnimation(.smooth) { router.openGamesPath = NavigationPath() }
        case .home:
            guard !router.homePath.isEmpty else { return }
            withAnimation(.smooth) { router.homePath = NavigationPath() }
        case .profile:
            break
        }
    }
}

// MARK: - Aperçu Xcode

/// Aperçu de la coquille à onglets, avec des objets d'environnement vides.
#Preview {
    MainTabView()
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
        .environment(MessagingCenter.shared)
}
