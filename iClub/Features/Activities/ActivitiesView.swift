//
//  ActivitiesView.swift
//  iClub
//
//  Onglet « Cours » : les cours et événements du club, regroupés par type,
//  filtrables par sport. Ceux où le membre est inscrit viennent en tête.
//
//  Un entraîneur voit en plus un sélecteur « Le club » / « Mes cours » ; un
//  membre qui ne l'est pas ne le voit jamais.
//

import SwiftUI

/// Détail d'une activité, côté membre.
struct ActivityRoute: Hashable {
    let activityId: UUID
}

struct ActivitiesView: View {
    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog

    @State private var store = ActivitiesStore()
    /// Porté ici, et non par « Mes cours » : il survit au passage d'un segment
    /// à l'autre, et l'appel, la fiche et l'agenda le partagent.
    @State private var coachStore = CoachStore()
    @State private var sportFilter: Sport?
    @State private var space: Space = .club

    enum Space: Hashable {
        case club, coach
    }

    /// Le compte au nom duquel on agit : le sien, ou celui d'un enfant.
    private var profile: SessionProfile? { auth.activeProfile }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if profile?.isCoach == true {
                    Picker("Espace", selection: $space) {
                        Text("Le club").tag(Space.club)
                        Text("Mes cours").tag(Space.coach)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                }

                switch space {
                case .club:
                    clubContent
                case .coach:
                    if let profile {
                        CoachSpaceView(profile: profile, store: coachStore)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Cours et événements")
        .navigationDestination(for: ActivityRoute.self) { route in
            ActivityDetailView(activityId: route.activityId, store: store)
        }
        .coachDestinations(store: coachStore)
        .task(id: profile?.id) {
            guard let profile else { return }
            await store.load(clubId: profile.clubId, profileId: profile.id)
        }
        .refreshable {
            switch space {
            case .club: await store.reload()
            case .coach: await coachStore.reload()
            }
        }
        .animation(.smooth(duration: 0.25), value: sportFilter)
    }

    // MARK: - Le club

    @ViewBuilder
    private var clubContent: some View {
        if case .failed(let message) = store.phase {
            InlineMessage(kind: .error, message: message)
                .padding(.horizontal, 20)
        } else if store.activities.isEmpty, store.phase != .ready {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(height: 170, cornerRadius: Radius.card)
                }
            }
            .padding(.horizontal, 20)
        } else if store.activities.isEmpty {
            PhasePlaceholder(
                systemImage: "figure.run",
                title: "Rien pour l'instant",
                message: "Aucun cours ni événement ouvert à l'inscription pour l'instant.",
                accent: Brand.pine800
            )
        } else {
            sportFilterBar

            let visible = store.activities.filter { sportFilter == nil || $0.sport == sportFilter }
            let mine = visible.filter { store.isEnrolled($0.id) }
            let others = visible.filter { !store.isEnrolled($0.id) }

            if visible.isEmpty {
                PhasePlaceholder(
                    systemImage: "figure.run",
                    title: "Rien dans ce sport",
                    message: "Aucun cours ni événement ouvert pour ce sport en ce moment."
                )
            }

            if !mine.isEmpty {
                section(title: "Vos inscriptions", activities: mine)
            }

            ForEach(ActivityType.displayGroups, id: \.title) { group in
                let items = others.filter { group.types.contains($0.type) }
                if !items.isEmpty {
                    section(title: group.title, activities: items)
                }
            }
        }
    }

    private func section(title: String, activities: [Activity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .metaLabelStyle()
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                ForEach(activities) { activity in
                    NavigationLink(value: ActivityRoute(activityId: activity.id)) {
                        ActivityCard(
                            activity: activity,
                            courtName: courtName(activity.courtId),
                            coachName: store.coachName(for: activity),
                            placesLabel: store.placesLabel(for: activity),
                            nextSession: store.nextSession(of: activity.id),
                            isEnrolled: store.isEnrolled(activity.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    // MARK: - Filtre par sport

    @ViewBuilder
    private var sportFilterBar: some View {
        let sports = store.sports
        if sports.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    sportChip(nil)
                    ForEach(sports) { sportChip($0) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Même pastille que le choix du sport dans « Réserver ».
    private func sportChip(_ sport: Sport?) -> some View {
        let isSelected = sportFilter == sport
        let tint = sport?.accent ?? Brand.navy700

        return Button {
            guard !isSelected else { return }
            sportFilter = sport
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                if let sport {
                    Image(systemName: sport.symbolName)
                        .font(.caption.weight(.semibold))
                }
                Text(sport?.displayName ?? "Tous")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color.white : tint)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? tint : tint.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
