//
//  MainTabView.swift
//  iClub
//
//  Barre de navigation à 5 items. On s'appuie sur le `TabView` système : c'est
//  lui qui fournit le matériau Liquid Glass, la capsule derrière l'item actif
//  et l'effet de bord au défilement — reproduire cela à la main donnerait un
//  résultat moins fidèle qu'Apple, pas plus.
//
//  Un re-tap sur l'onglet déjà actif revient à la racine de sa pile.
//
//  Par-dessus les onglets flotte la bulle de messagerie, qui ouvre la liste
//  des conversations en feuille.
//

import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case reservations
    case openGames
    case activities
    case profile
}

/// Historique « Mes réservations », poussé sur la racine de l'onglet
/// « Réserver ».
struct ReservationHistoryRoute: Hashable {}

struct MainTabView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router
    @Environment(MessagingCenter.self) private var messaging

    @Namespace private var bubbleNamespace
    @Environment(\.scenePhase) private var scenePhase

    /// Intercepte la sélection pour détecter le re-tap sur l'onglet courant.
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

    var body: some View {
        @Bindable var router = router
        @Bindable var messaging = messaging

        return TabView(selection: tabSelection) {
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

            Tab("Cours", systemImage: "figure.run", value: AppTab.activities) {
                NavigationStack(path: $router.activitiesPath) {
                    ActivitiesView()
                        .appTopBar()
                }
            }

            Tab("Profil", systemImage: "person.crop.circle.fill", value: AppTab.profile) {
                NavigationStack {
                    ProfileView()
                        .appTopBar()
                }
            }
        }
        .tint(Brand.navy700)
        .overlay(alignment: .bottomTrailing) { messageBubble }
        .sheet(isPresented: $messaging.isSheetPresented) {
            MessagesSheet()
                .navigationTransition(.zoom(sourceID: "message-bubble", in: bubbleNamespace))
        }
        .alert("Messagerie", isPresented: messagingErrorBinding) {
            Button("OK") { messaging.errorMessage = nil }
        } message: {
            Text(messaging.errorMessage ?? "")
        }
        // Charge le catalogue du club dès que la session est connue, puis reste
        // à l'écoute des modifications faites par l'admin (Realtime).
        .task(id: auth.sessionProfile?.clubId) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await catalog.activate(clubId: clubId)
        }
        // Conversations et non-lus, tenus à jour en temps réel.
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
        // Tap sur une notification de partie : on ouvre directement la partie,
        // y compris quand la notification a lancé l'app à froid.
        // Une réservation prise sur le web doit aussi avoir son rappel : on
        // refait la liste à chaque retour dans l'app.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let profile = auth.sessionProfile else { return }
            Task { await BookingReminders.refresh(for: profile) }
        }
        // Tap sur un rappel de réservation : l'historique des réservations.
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
    @ViewBuilder
    private var messageBubble: some View {
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
            .matchedTransitionSource(id: "message-bubble", in: bubbleNamespace)
            .accessibilityLabel(bubbleAccessibilityLabel)
            .padding(.trailing, 20)
            // Au-dessus de la barre d'onglets flottante.
            .padding(.bottom, 92)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var bubbleAccessibilityLabel: String {
        switch messaging.totalUnread {
        case 0: "Messages"
        case 1: "Messages, 1 non lu"
        case let count: "Messages, \(count) non lus"
        }
    }

    private var messagingErrorBinding: Binding<Bool> {
        Binding(
            get: { messaging.errorMessage != nil },
            set: { if !$0 { messaging.errorMessage = nil } }
        )
    }

    // MARK: - Navigation

    private func openAttendance(_ sessionId: UUID) {
        var path = NavigationPath()
        path.append(AttendanceRoute(sessionId: sessionId))
        router.activitiesPath = path
        router.selectedTab = .activities
    }

    private func openGame(_ gameId: UUID) {
        var path = NavigationPath()
        path.append(OpenGameDetailRoute(gameId: gameId))
        router.openGamesPath = path
        router.selectedTab = .openGames
    }

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

#Preview {
    MainTabView()
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
        .environment(MessagingCenter.shared)
}
