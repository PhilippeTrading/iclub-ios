//
//  ActivitiesView.swift
//  iClub
//
//  Rôle
//    Onglet « Cours » : les cours et événements du club, regroupés par type,
//    filtrables par sport. Ceux où le membre est inscrit viennent en tête.
//
//    Un entraîneur voit en plus un sélecteur « Le club » / « Mes cours » ; un
//    membre qui ne l'est pas ne le voit jamais.
//
//  Place dans l'application
//    Racine de l'onglet « Cours » de la barre d'onglets (MainTabView), dans la
//    pile `AppRouter.activitiesPath`. Un tap sur une carte pousse le détail
//    (ActivityDetailView, route `ActivityRoute`). Le segment « Mes cours »
//    affiche CoachSpaceView, dont les écrans (fiche d'un cours, appel, création,
//    fiche d'élève) sont déclarés ici par `.coachDestinations(store:)`, pour
//    que le rappel « faire l'appel » puisse ouvrir l'appel directement dans
//    cette pile.
//
//  Données
//    ActivitiesStore (activités publiées, séances à venir, inscriptions
//    lisibles, noms des entraîneurs) et ClubCatalog (noms des terrains).
//    L'espace entraîneur lit CoachStore. Les deux magasins vivent ici, en
//    `@State`, le temps de vie de l'onglet.
//
//  États affichés (« Le club »)
//    - échec du premier chargement : message d'erreur en ligne ;
//    - chargement : trois squelettes de carte ;
//    - aucune activité publiée : carte « Rien pour l'instant » ;
//    - filtre sans résultat : carte « Rien dans ce sport » ;
//    - sinon : « Vos inscriptions », puis « Cours collectifs », « Leçons »,
//      « Stages », « Événements » (ActivityType.displayGroups).
//
//  Points d'attention
//    - Le profil lu est `auth.activeProfile` : celui de l'enfant quand le parent
//      agit pour lui depuis le sélecteur de compte. Le chargement repart à
//      chaque changement de profil (`.task(id:)`).
//    - Attention : le segment choisi (`space`) n'est pas remis à « Le club »
//      quand le profil actif cesse d'être entraîneur (passage au compte d'un
//      enfant). Si « Mes cours » était affiché, l'espace entraîneur reste à
//      l'écran pour le profil de l'enfant, sans sélecteur pour en sortir.
//

import SwiftUI

/// Détail d'une activité, côté membre.
struct ActivityRoute: Hashable {
    /// Identifiant de l'activité (`activites.id`).
    let activityId: UUID
}

/// Écran racine de l'onglet « Cours ».
struct ActivitiesView: View {
    /// Session et profil actif (le membre ou l'enfant choisi).
    @Environment(AuthController.self) private var auth
    /// Catalogue du club, pour les noms des terrains.
    @Environment(ClubCatalog.self) private var catalog

    /// Magasin côté membre, partagé avec le détail d'une activité.
    @State private var store = ActivitiesStore()
    /// Porté ici, et non par « Mes cours » : il survit au passage d'un segment
    /// à l'autre, et l'appel, la fiche et l'agenda le partagent.
    @State private var coachStore = CoachStore()
    /// Sport retenu par le filtre ; `nil` : tous les sports.
    @State private var sportFilter: Sport?
    /// Segment affiché : le club, ou l'espace entraîneur.
    @State private var space: Space = .club

    /// Les deux espaces de l'onglet : « Le club » (côté membre) et « Mes cours »
    /// (côté entraîneur).
    enum Space: Hashable {
        /// club : les cours et événements du club ; coach : l'espace entraîneur.
        case club, coach
    }

    /// Le compte au nom duquel on agit : le sien, ou celui d'un enfant.
    private var profile: SessionProfile? { auth.activeProfile }

    /// Sélecteur d'espace (entraîneur seulement), puis le contenu de l'espace,
    /// dans un défilement vertical.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Sélecteur « Le club » / « Mes cours », réservé aux entraîneurs
                // (`club_members.est_entraineur` ou ancien rôle « entraineur »).
                if profile?.isCoach == true {
                    Picker("Espace", selection: $space) {
                        Text("Le club").tag(Space.club)
                        Text("Mes cours").tag(Space.coach)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                }

                // Contenu de l'espace choisi.
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
        // Écrans de l'espace entraîneur, empilés dans la même pile.
        .coachDestinations(store: coachStore)
        // Chargement côté membre, relancé à chaque changement de profil actif.
        .task(id: profile?.id) {
            guard let profile else { return }
            await store.load(clubId: profile.clubId, profileId: profile.id)
        }
        // « Tirer pour rafraîchir » recharge l'espace affiché seulement.
        .refreshable {
            switch space {
            case .club: await store.reload()
            case .coach: await coachStore.reload()
            }
        }
        .animation(.smooth(duration: 0.25), value: sportFilter)
    }

    // MARK: - Le club

    /// Contenu du segment « Le club » : erreur, squelettes, état vide, ou la
    /// liste filtrée et regroupée.
    @ViewBuilder
    private var clubContent: some View {
        // Échec du premier chargement (un échec de rafraîchissement garde la
        // liste, voir ActivitiesStore.reload).
        if case .failed(let message) = store.phase {
            InlineMessage(kind: .error, message: message)
                .padding(.horizontal, 20)
        } else if store.activities.isEmpty, store.phase != .ready {
            // Chargement : squelettes à la hauteur des cartes.
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(height: 170, cornerRadius: Radius.card)
                }
            }
            .padding(.horizontal, 20)
        } else if store.activities.isEmpty {
            // Chargé, mais le club n'a rien publié.
            PhasePlaceholder(
                systemImage: "figure.run",
                title: "Rien pour l'instant",
                message: "Aucun cours ni événement ouvert à l'inscription pour l'instant.",
                accent: Brand.pine800
            )
        } else {
            // Filtre par sport (masqué s'il n'y a qu'un sport).
            sportFilterBar

            // Activités du sport choisi, séparées entre celles où le profil est
            // inscrit (ou en liste d'attente) et les autres.
            let visible = store.activities.filter { sportFilter == nil || $0.sport == sportFilter }
            let mine = visible.filter { store.isEnrolled($0.id) }
            let others = visible.filter { !store.isEnrolled($0.id) }

            // Filtre sans résultat.
            if visible.isEmpty {
                PhasePlaceholder(
                    systemImage: "figure.run",
                    title: "Rien dans ce sport",
                    message: "Aucun cours ni événement ouvert pour ce sport en ce moment."
                )
            }

            // Inscriptions du profil, en tête.
            if !mine.isEmpty {
                section(title: "Vos inscriptions", activities: mine)
            }

            // Les autres, par groupe de types, dans l'ordre du web ; un groupe
            // vide n'est pas affiché.
            ForEach(ActivityType.displayGroups, id: \.title) { group in
                let items = others.filter { group.types.contains($0.type) }
                if !items.isEmpty {
                    section(title: group.title, activities: items)
                }
            }
        }
    }

    /// Une section titrée de cartes d'activité, chacune menant à son détail.
    /// - Parameters:
    ///   - title: intitulé de la section (« Vos inscriptions », « Stages »...).
    ///   - activities: activités de la section, dans l'ordre du magasin (nom).
    /// - Returns: l'intitulé et la pile de cartes.
    private func section(title: String, activities: [Activity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .metaLabelStyle()
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                ForEach(activities) { activity in
                    // Toute la carte est le lien vers le détail.
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

    /// Nom d'un terrain du catalogue du club.
    /// - Parameter id: identifiant du terrain (`courts.id`), ou `nil`.
    /// - Returns: le nom du terrain, ou `nil` s'il est absent ou inconnu.
    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    // MARK: - Filtre par sport

    /// Rangée défilante de pastilles « Tous », puis un sport par pastille.
    /// Affichée seulement quand les activités couvrent au moins deux sports.
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
    /// - Parameter sport: le sport de la pastille, ou `nil` pour « Tous ».
    /// - Returns: le bouton, plein de la couleur du sport quand il est choisi,
    ///   teinté à 12 % sinon.
    private func sportChip(_ sport: Sport?) -> some View {
        let isSelected = sportFilter == sport
        let tint = sport?.accent ?? Brand.navy700

        return Button {
            // Retaper la pastille déjà choisie ne fait rien (pas de vibration).
            guard !isSelected else { return }
            sportFilter = sport
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                // Icône du sport ; « Tous » n'en a pas.
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
        // VoiceOver annonce la pastille choisie comme « sélectionnée ».
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
