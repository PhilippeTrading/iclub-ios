//
//  CoachSpaceView.swift
//  iClub
//
//  « Mes cours », l'espace de l'entraîneur, dans l'onglet « Activités ».
//  Deux niveaux : « Cette semaine » (l'écran qu'il ouvre en arrivant au club,
//  avec l'appel de la séance du jour à un tap) et « Mes cours ».
//

import SwiftUI

// MARK: - Routes

struct CoachCourseRoute: Hashable { let activityId: UUID }
struct AttendanceRoute: Hashable { let sessionId: UUID }
struct CreateCourseRoute: Hashable {}
struct CourseCreatedRoute: Hashable { let result: CourseCreationResult; let nom: String }

extension View {
    /// Destinations de l'espace entraîneur, déclarées à la racine de l'onglet
    /// pour partager le même magasin.
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

struct CoachSpaceView: View {
    let profile: SessionProfile
    let store: CoachStore

    @Environment(ClubCatalog.self) private var catalog
    @State private var level: Level = .week

    enum Level: Hashable { case week, courses }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Affichage", selection: $level) {
                Text("Cette semaine").tag(Level.week)
                Text("Mes cours").tag(Level.courses)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            if case .failed(let message) = store.phase {
                InlineMessage(kind: .error, message: message)
                    .padding(.horizontal, 20)
            } else if store.phase != .ready && store.activities.isEmpty {
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
        .task(id: profile.id) {
            await store.load(clubId: profile.clubId, coachId: profile.id)
        }
        // Sans autorisation, aucun rappel d'appel ne peut sonner.
        .offersNotificationOptIn(when: true, message: NotificationOptInSheet.attendanceMessage)
        .onReceive(NotificationCenter.default.publisher(for: PushService.authorizationGranted)) { _ in
            Task { await store.reload() }
        }
    }

    // MARK: - Cette semaine

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

    private func weekRow(_ session: ActivitySession) -> some View {
        let activity = store.activity(id: session.activiteId)

        return SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
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

            if store.activities.isEmpty {
                PhasePlaceholder(
                    systemImage: "figure.tennis",
                    title: "Aucun cours",
                    message: "Créez votre premier cours : dans vos créneaux, il est en ligne tout de suite."
                )
            }

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

    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }
}
