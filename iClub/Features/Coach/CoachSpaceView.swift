//
//  CoachSpaceView.swift
//  iClub
//
//  Rôle
//    « Mes cours », l'espace de l'entraîneur, dans l'onglet « Cours ».
//    Deux niveaux : « Cette semaine » (l'écran qu'il ouvre en arrivant au club,
//    avec l'appel de la séance du jour à un tap) et « Mes cours ».
//
//  Place dans l'application
//    Affiché par ActivitiesView quand l'entraîneur choisit le segment « Mes
//    cours ». Ce fichier déclare aussi les routes de l'espace entraîneur et
//    `coachDestinations(store:)`, posé à la racine de l'onglet, qui relie
//    chaque route à son écran : fiche d'un cours (CoachCourseView), appel
//    (AttendanceView), création (CreateCourseView), confirmation
//    (CourseCreatedView), fiche d'un élève (StudentDetailView).
//
//  Données
//    CoachStore, chargé ici pour le profil reçu (`.task(id:)`), et ClubCatalog
//    pour les noms des terrains.
//
//  États affichés
//    Erreur du premier chargement (message en ligne), chargement (deux
//    squelettes), puis le niveau choisi : agenda des sept jours (ou carte
//    « Aucune séance cette semaine »), ou liste des cours (ou carte « Aucun
//    cours »), toujours précédée du bouton « Créer un cours ».
//
//  Effets de bord
//    Propose l'écran d'activation des notifications (sans elles, aucun rappel
//    d'appel ne peut sonner), et recharge le magasin dès que l'autorisation est
//    accordée, ce qui programme les rappels.
//

import SwiftUI

// MARK: - Routes

/// Fiche d'un cours, côté entraîneur. `activityId` : identifiant du cours
/// (`activites.id`).
struct CoachCourseRoute: Hashable { let activityId: UUID }
/// Appel d'une séance ; c'est aussi la route qu'ouvre le rappel « faire
/// l'appel » (MainTabView). `sessionId` : identifiant de la séance
/// (`activite_seances.id`).
struct AttendanceRoute: Hashable { let sessionId: UUID }
/// Formulaire de création d'un cours.
struct CreateCourseRoute: Hashable {}
/// Écran de confirmation après création, qui remplace le formulaire dans la
/// pile. `result` : réponse de la fonction SQL `creer_activite` ; `nom` : nom
/// du cours saisi, repris dans le message.
struct CourseCreatedRoute: Hashable { let result: CourseCreationResult; let nom: String }

/// Branchement des écrans de l'espace entraîneur sur une pile de navigation.
extension View {
    /// Destinations de l'espace entraîneur, déclarées à la racine de l'onglet
    /// pour partager le même magasin.
    /// - Parameter store: le magasin de l'entraîneur, transmis à chaque écran.
    /// - Returns: la vue, avec les cinq destinations de navigation.
    func coachDestinations(store: CoachStore) -> some View {
        self
            .navigationDestination(for: CoachCourseRoute.self) { route in
                CoachCourseView(activityId: route.activityId, store: store)
            }
            .navigationDestination(for: AttendanceRoute.self) { route in
                AttendanceView(sessionId: route.sessionId, store: store)
            }
            .navigationDestination(for: CreateCourseRoute.self) { _ in
                CreateCourseView(store: store)
            }
            .navigationDestination(for: CourseCreatedRoute.self) { route in
                CourseCreatedView(result: route.result, nom: route.nom)
            }
            .navigationDestination(for: StudentRoute.self) { route in
                StudentDetailView(route: route, store: store)
            }
    }
}

// MARK: - Espace

/// Espace entraîneur : sélecteur « Cette semaine » / « Mes cours » et son
/// contenu.
struct CoachSpaceView: View {
    /// Profil de l'entraîneur (le profil actif de la session).
    let profile: SessionProfile
    /// Magasin partagé, possédé par ActivitiesView.
    let store: CoachStore

    /// Catalogue du club, pour les noms des terrains.
    @Environment(ClubCatalog.self) private var catalog
    /// Niveau affiché ; « Cette semaine » à l'ouverture.
    @State private var level: Level = .week

    /// Les deux niveaux de l'espace : l'agenda des sept jours, la liste des
    /// cours.
    enum Level: Hashable { case week, courses }

    /// Sélecteur de niveau, puis erreur, squelettes ou contenu du niveau.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Affichage", selection: $level) {
                Text("Cette semaine").tag(Level.week)
                Text("Mes cours").tag(Level.courses)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            // Échec du premier chargement.
            if case .failed(let message) = store.phase {
                InlineMessage(kind: .error, message: message)
                    .padding(.horizontal, 20)
            } else if store.phase != .ready && store.activities.isEmpty {
                // Premier chargement : squelettes.
                VStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in SkeletonBlock(height: 120, cornerRadius: Radius.card) }
                }
                .padding(.horizontal, 20)
            } else {
                switch level {
                case .week: weekAgenda
                case .courses: courseList
                }
            }
        }
        // Chargement pour ce profil, relancé s'il change.
        .task(id: profile.id) {
            await store.load(clubId: profile.clubId, coachId: profile.id)
        }
        // Sans autorisation, aucun rappel d'appel ne peut sonner.
        .offersNotificationOptIn(when: true, message: NotificationOptInSheet.attendanceMessage)
        // Autorisation accordée : rechargement, qui programme les rappels.
        .onReceive(NotificationCenter.default.publisher(for: PushService.authorizationGranted)) { _ in
            Task { await store.reload() }
        }
    }

    // MARK: - Cette semaine

    /// Les séances des sept prochains jours (hors annulées), une carte par
    /// séance, ou une carte d'attente s'il n'y en a aucune.
    @ViewBuilder
    private var weekAgenda: some View {
        let sessions = store.weekSessions
        if sessions.isEmpty {
            PhasePlaceholder(
                systemImage: "calendar",
                title: "Aucune séance cette semaine",
                message: "Vos séances des sept prochains jours s'afficheront ici."
            )
        } else {
            VStack(spacing: 10) {
                ForEach(sessions) { session in
                    weekRow(session)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Carte d'une séance de l'agenda : jour, cours, horaire et terrain, avec
    /// les boutons d'appel et de fiche.
    /// - Parameter session: la séance.
    /// - Returns: la carte.
    private func weekRow(_ session: ActivitySession) -> some View {
        let activity = store.activity(id: session.activiteId)

        return SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    // « Aujourd'hui », « Demain » ou le jour en toutes lettres,
                    // puis le cours et « horaire · terrain ».
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.date.relativeFrenchDayTitle)
                            .metaLabelStyle()
                        Text(activity?.nom ?? "Cours")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text([session.slot.label, courtName(session.courtId)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer(minLength: 8)
                    // Séance passée en « faite » : l'appel est complet.
                    if session.statut == .faite {
                        BrandChip(title: "Appel fait", systemImage: "checkmark", tint: Brand.success)
                            .fixedSize()
                    }
                }

                HStack(spacing: 10) {
                    // L'appel est mis en avant le jour même ; les autres jours,
                    // on passe par la fiche du cours.
                    if session.isToday {
                        NavigationLink(value: AttendanceRoute(sessionId: session.id)) {
                            Label(session.statut == .faite ? "Revoir l'appel" : "Faire l'appel", systemImage: "checklist")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(activity?.sport.accent ?? Brand.navy700)
                    }
                    // Fiche du cours : pleine largeur quand elle est seule.
                    NavigationLink(value: CoachCourseRoute(activityId: session.activiteId)) {
                        Text("Fiche du cours")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .frame(maxWidth: session.isToday ? nil : .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Mes cours

    /// Bouton « Créer un cours », puis les cours de l'entraîneur (ou une carte
    /// d'invitation s'il n'en a aucun).
    @ViewBuilder
    private var courseList: some View {
        VStack(spacing: 12) {
            NavigationLink(value: CreateCourseRoute()) {
                Label("Créer un cours", systemImage: "plus")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.navy700)

            // Aucun cours encadré.
            if store.activities.isEmpty {
                PhasePlaceholder(
                    systemImage: "figure.tennis",
                    title: "Aucun cours",
                    message: "Créez votre premier cours : dans vos créneaux, il est en ligne tout de suite."
                )
            }

            // Une carte par cours, avec son statut et le décompte des inscrits ;
            // un tap ouvre la fiche du cours.
            ForEach(store.activities) { activity in
                NavigationLink(value: CoachCourseRoute(activityId: activity.id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ActivityCard(
                            activity: activity,
                            courtName: courtName(activity.courtId),
                            coachName: nil,
                            placesLabel: store.placesLabel(for: activity),
                            nextSession: store.nextSession(of: activity.id),
                            isEnrolled: false,
                            showsStatus: true
                        )
                        // Cours « proposé » : créé hors des créneaux alloués, il
                        // attend la validation du club (statut décidé par
                        // creer_activite).
                        if activity.statut == .proposee {
                            InlineMessage(
                                kind: .info,
                                message: "Créé hors de vos créneaux : le club doit le valider avant que les membres puissent s'inscrire. Aucun terrain n'est bloqué d'ici là."
                            )
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    /// Nom d'un terrain du catalogue du club.
    /// - Parameter id: identifiant du terrain, ou `nil`.
    /// - Returns: son nom, ou `nil` s'il est absent ou inconnu.
    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }
}
