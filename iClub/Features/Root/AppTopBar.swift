//
//  AppTopBar.swift
//  iClub
//
//  La barre du haut, commune aux cinq onglets, au-dessus de leur titre :
//    • à gauche, le sélecteur de compte : passer au compte d'un enfant, ou en
//      ajouter un ;
//    • à droite, la cloche qui ouvre l'historique des notifications.
//

import SwiftUI

extension View {
    /// Pose la barre du haut sur la racine d'un onglet.
    func appTopBar() -> some View {
        modifier(AppTopBar())
    }
}

private struct AppTopBar: ViewModifier {
    @Environment(AuthController.self) private var auth

    @Environment(MessagingCenter.self) private var messaging
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsNotifications = false
    /// Notifications arrivées depuis la dernière ouverture de la cloche.
    @State private var unseenCount = 0

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Toujours là, même sans enfant : c'est aussi là qu'on en ajoute un.
                if auth.sessionProfile != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        AccountSwitcher()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsNotifications = true
                    } label: {
                        Image(systemName: "bell")
                            // Pastille rouge tant qu'il reste des notifications
                            // non lues, avec leur nombre.
                            .overlay(alignment: .topTrailing) {
                                if unseenCount > 0 {
                                    Text(unseenCount > 9 ? "9+" : "\(unseenCount)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(Brand.error, in: .capsule)
                                        .offset(x: 8, y: -7)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .animation(.snappy, value: unseenCount)
                    }
                    .accessibilityLabel(unseenCount > 0 ? "Notifications, \(unseenCount) non lue\(unseenCount > 1 ? "s" : "")" : "Notifications")
                }
            }
            .sheet(isPresented: $showsNotifications, onDismiss: refreshBadge) {
                NotificationHistoryView()
            }
            .task(id: auth.sessionProfile?.id) { refreshBadge() }
            // Retour dans l'app, nouveau message reçu : la pastille se remet à jour.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshBadge() }
            }
            .onChange(of: messaging.totalUnread) { _, _ in refreshBadge() }
            .onReceive(NotificationCenter.default.publisher(for: NotificationHistoryService.seenNotification)) { _ in
                unseenCount = 0
            }
    }

    private func refreshBadge() {
        Task {
            let items = await NotificationHistoryService.load(clubId: auth.sessionProfile?.clubId)
            unseenCount = NotificationHistoryService.unseenCount(items)
        }
    }
}

// MARK: - Sélecteur de compte

/// Le compte au nom duquel l'app agit. À la connexion, c'est toujours le sien ;
/// un tap permet de passer à celui d'un enfant, puis d'en revenir.
private struct AccountSwitcher: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var isAddingChild = false

    var body: some View {
        Menu {
            if let me = auth.sessionProfile {
                Button {
                    switchTo(nil)
                } label: {
                    Label(me.displayName + " (moi)", systemImage: auth.isActingForChild ? "person" : "checkmark")
                }
            }

            if !auth.managedChildren.isEmpty {
                Section("Comptes famille") {
                    ForEach(auth.managedChildren) { child in
                        Button {
                            switchTo(child.profileId)
                        } label: {
                            Label(child.displayName, systemImage: auth.actingChildId == child.profileId ? "checkmark" : "person.crop.circle")
                        }
                    }
                }
            }

            Section {
                Button {
                    isAddingChild = true
                } label: {
                    Label("Ajouter un enfant", systemImage: "person.badge.plus")
                }
            }
        } label: {
            if let active = auth.activeProfile {
                HStack(spacing: 6) {
                    AvatarView(url: active.avatarUrl, initials: active.initials, size: 26)
                    Text(active.prenom ?? active.displayName)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                // Agir pour un enfant se voit en un coup d'œil.
                .foregroundStyle(auth.isActingForChild ? Brand.clay800 : Brand.navy700)
            }
        }
        .accessibilityLabel(auth.isActingForChild ? "Compte de \(auth.activeProfile?.displayName ?? "l'enfant"), changer de compte" : "Changer de compte")
        // Même formulaire que « Ma famille » dans le profil.
        .sheet(isPresented: $isAddingChild) {
            if let clubId = auth.sessionProfile?.clubId {
                AddChildSheet(clubId: clubId) {
                    await auth.reloadFamily()
                }
            }
        }
    }

    private func switchTo(_ childId: UUID?) {
        Haptics.selection()
        auth.act(for: childId)
        // Les écrans ouverts appartenaient à l'autre compte : on repart des
        // racines, sur l'onglet courant.
        let tab = router.selectedTab
        router.reset()
        router.selectedTab = tab
    }
}
