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

import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case book
    case openGames
    case reservations
    case profile
}

struct MainTabView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var reservationsPath = NavigationPath()

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

        return TabView(selection: tabSelection) {
            Tab("Accueil", systemImage: "house.fill", value: AppTab.home) {
                // Pile propre à l'accueil : la carte de prochaine réservation
                // ouvre le même détail que « Mes réservations ».
                NavigationStack(path: $router.homePath) {
                    HomeView()
                }
            }

            Tab("Réserver", systemImage: "calendar.badge.plus", value: AppTab.book) {
                NavigationStack(path: $router.bookingPath) {
                    BookingView()
                }
            }

            // Item central : c'est le cœur de la nouveauté produit, il porte un
            // glyphe plein encapsulé là où les quatre autres sont des contours.
            Tab("Parties", systemImage: "figure.tennis.circle.fill", value: AppTab.openGames) {
                NavigationStack(path: $router.openGamesPath) {
                    OpenGamesView()
                }
            }

            Tab("Réservations", systemImage: "list.bullet.rectangle.portrait", value: AppTab.reservations) {
                NavigationStack(path: $reservationsPath) {
                    ReservationsView()
                }
            }

            // TODO(étape 2) : remplacer par la photo de profil réelle une fois
            // l'upload d'avatar en place, comme l'App Store le fait avec iCloud.
            Tab("Profil", systemImage: "person.crop.circle.fill", value: AppTab.profile) {
                NavigationStack {
                    ProfileView()
                }
            }
        }
        .tint(Brand.navy700)
        // Charge le catalogue du club dès que la session est connue, puis reste
        // à l'écoute des modifications faites par l'admin (Realtime).
        .task(id: auth.sessionProfile?.clubId) {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            await catalog.activate(clubId: clubId)
        }
        // Tap sur une suggestion de partie : on ouvre l'onglet des parties,
        // y compris quand la notification a lancé l'app à froid.
        .task {
            if ReengagementService.consumePendingOpenGames() { openGamesTab() }
            for await _ in NotificationCenter.default.notifications(named: ReengagementService.openGamesRequested) {
                _ = ReengagementService.consumePendingOpenGames()
                openGamesTab()
            }
        }
    }

    private func openGamesTab() {
        router.openGamesPath = NavigationPath()
        router.selectedTab = .openGames
    }

    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .book:
            guard !router.bookingPath.isEmpty else { return }
            withAnimation(.smooth) { router.bookingPath = NavigationPath() }
        case .openGames:
            guard !router.openGamesPath.isEmpty else { return }
            withAnimation(.smooth) { router.openGamesPath = NavigationPath() }
        case .reservations:
            guard !reservationsPath.isEmpty else { return }
            withAnimation(.smooth) { reservationsPath = NavigationPath() }
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
}
