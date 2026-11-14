//
//  AppTopBar.swift
//  iClub
//
//  La barre du haut, commune aux cinq onglets, au-dessus de leur titre :
//    • à gauche, le sélecteur de compte : passer au compte d'un enfant, ou en
//      ajouter un ;
//    • à droite, la cloche qui ouvre l'historique des notifications.
//
//  Rôle
//    Modificateur de vue (`appTopBar()`) posé par `MainTabView` sur la racine
//    de chaque onglet. Il ajoute les deux boutons à la barre d'outils, la
//    pastille du nombre de notifications non vues et la feuille de
//    l'historique (`NotificationHistoryView`).
//
//  Données
//    - Le compte connecté, les enfants gérés et l'enfant sélectionné viennent
//      de `AuthController` (comptes famille, fonction SQL `mes_profils_geres`).
//    - Le nombre de nouveautés est recalculé par
//      `NotificationHistoryService` (annonces du club, parties proposées,
//      messages encore présents dans le centre de notifications), comparé à
//      la date de dernière consultation gardée sur l'appareil.
//
//  Règles métier
//    Passer au compte d'un enfant change la personne au nom de qui les onglets
//    lisent et agissent (réservations, parties, cours) ; c'est toujours le
//    parent connecté qui écrit en base. Les fonctions SQL qui agissent pour un
//    tiers (rejoindre une partie, par exemple) vérifient son droit
//    (`peut_agir_pour`) ; une réservation classique, elle, est simplement
//    créée au nom du parent. Toutes les piles de navigation repartent de leur
//    racine, car les écrans ouverts appartenaient à l'autre compte.
//
//  Effets de bord
//    Aucun en base. Ajouter un enfant passe par `AddChildSheet` (profil), qui
//    écrit lui-même ; la famille est ensuite relue.
//
//  Points d'attention
//    Le modificateur est posé sur chacune des cinq racines : chaque onglet déjà
//    chargé a sa propre cloche, qui relit tout l'historique à chaque
//    rafraîchissement de sa pastille. Les cloches se remettent à zéro
//    ensemble grâce à `NotificationHistoryService.seenNotification`.
//

import SwiftUI

// MARK: - Point d'entrée

/// Raccourci d'écriture pour poser la barre du haut sur une vue.
extension View {
    /// Pose la barre du haut sur la racine d'un onglet.
    ///
    /// - Returns: la vue munie du sélecteur de compte (à gauche), de la cloche
    ///   des notifications (à droite) et de la feuille d'historique.
    func appTopBar() -> some View {
        modifier(AppTopBar())
    }
}

// MARK: - Barre du haut

/// Modificateur qui ajoute à la barre d'outils le sélecteur de compte et la
/// cloche des notifications, avec sa pastille de nouveautés.
private struct AppTopBar: ViewModifier {
    /// Session : sert à savoir si un compte est connecté et quel est son club.
    @Environment(AuthController.self) private var auth

    /// Messagerie : un nouveau message reçu relance le calcul de la pastille.
    @Environment(MessagingCenter.self) private var messaging
    /// Premier plan ou arrière-plan de l'app.
    @Environment(\.scenePhase) private var scenePhase

    /// Vrai pendant que la feuille d'historique est ouverte.
    @State private var showsNotifications = false
    /// Notifications arrivées depuis la dernière ouverture de la cloche.
    @State private var unseenCount = 0

    /// Ajoute les deux boutons à la barre d'outils de l'écran, la feuille de
    /// l'historique et les relectures de la pastille.
    ///
    /// - Parameter content: racine de l'onglet.
    /// - Returns: la racine munie de la barre du haut.
    func body(content: Content) -> some View {
        content
            .toolbar {
                // Toujours là, même sans enfant : c'est aussi là qu'on en ajoute un.
                if auth.sessionProfile != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        AccountSwitcher()
                    }
                }
                // Cloche de l'historique des notifications.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsNotifications = true
                    } label: {
                        Image(systemName: "bell")
                            // Pastille rouge tant qu'il reste des notifications
                            // non lues, avec leur nombre.
                            .overlay(alignment: .topTrailing) {
                                // Plafonnée à « 9+ » pour tenir sur la cloche.
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
                    // VoiceOver annonce le nombre de non lues, accordé.
                    .accessibilityLabel(unseenCount > 0 ? "Notifications, \(unseenCount) non lue\(unseenCount > 1 ? "s" : "")" : "Notifications")
                }
            }
            // Historique des notifications ; à sa fermeture, la pastille est
            // recalculée.
            .sheet(isPresented: $showsNotifications, onDismiss: refreshBadge) {
                NotificationHistoryView()
            }
            // Premier calcul, puis à chaque changement de compte connecté.
            .task(id: auth.sessionProfile?.id) { refreshBadge() }
            // Retour dans l'app, nouveau message reçu : la pastille se remet à jour.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshBadge() }
            }
            .onChange(of: messaging.totalUnread) { _, _ in refreshBadge() }
            // L'historique vient d'être consulté (depuis n'importe quel
            // onglet) : la pastille disparaît aussitôt.
            .onReceive(NotificationCenter.default.publisher(for: NotificationHistoryService.seenNotification)) { _ in
                unseenCount = 0
            }
    }

    /// Recalcule la pastille : relit l'historique complet (annonces, parties
    /// proposées, messages) et compte les éléments postérieurs à la dernière
    /// consultation. Lancé dans une tâche détachée de l'appelant ; un échec
    /// de lecture donne simplement moins d'éléments, jamais d'erreur affichée.
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
///
/// Menu déroulant : le compte connecté (« moi »), les comptes famille dont il
/// est responsable, et l'ajout d'un enfant. Le bouton affiche la photo et le
/// prénom du compte actif, en couleur terre battue quand on agit pour un
/// enfant.
private struct AccountSwitcher: View {
    /// Session : compte connecté, enfants gérés, enfant sélectionné.
    @Environment(AuthController.self) private var auth
    /// Navigation : remise à zéro des piles au changement de compte.
    @Environment(AppRouter.self) private var router

    /// Vrai pendant que la feuille d'ajout d'un enfant est ouverte.
    @State private var isAddingChild = false

    /// Le menu des comptes, son étiquette et la feuille d'ajout d'un enfant.
    var body: some View {
        Menu {
            // Le compte connecté, coché quand on n'agit pour aucun enfant.
            if let me = auth.sessionProfile {
                Button {
                    switchTo(nil)
                } label: {
                    Label(me.displayName + " (moi)", systemImage: auth.isActingForChild ? "person" : "checkmark")
                }
            }

            // Les enfants gérés, s'il y en a ; l'enfant actif est coché.
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

            // Ajout d'un enfant, toujours proposé.
            Section {
                Button {
                    isAddingChild = true
                } label: {
                    Label("Ajouter un enfant", systemImage: "person.badge.plus")
                }
            }
        } label: {
            // Étiquette du menu : photo (ou initiales), prénom, chevron.
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
        // Une fois l'enfant créé, la liste des comptes famille est relue.
        .sheet(isPresented: $isAddingChild) {
            if let clubId = auth.sessionProfile?.clubId {
                AddChildSheet(clubId: clubId) {
                    await auth.reloadFamily()
                }
            }
        }
    }

    /// Change le compte au nom duquel l'app agit.
    ///
    /// - Parameter childId: profil de l'enfant à sélectionner, ou `nil` pour
    ///   revenir à son propre compte. Un identifiant qui n'est pas celui d'un
    ///   enfant géré est ignoré par `AuthController.act(for:)`, qui revient
    ///   alors au compte connecté.
    private func switchTo(_ childId: UUID?) {
        Haptics.selection()
        auth.act(for: childId)
        // Les écrans ouverts appartenaient à l'autre compte : on repart des
        // racines, sur l'onglet courant.
        // `reset()` efface aussi le sport, le jour et la surface retenus par le
        // tunnel de réservation.
        let tab = router.selectedTab
        router.reset()
        router.selectedTab = tab
    }
}
