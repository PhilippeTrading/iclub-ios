//
//  HomeView.swift
//  iClub
//
//  Premier écran après connexion.
//
//  Tout y est dérivé de la base : le compteur de terrains vient de `courts`,
//  l'heure de fermeture de `club_sport_settings`, la date de validité de
//  l'adhésion active, le solde de crédits d'un recalcul. Aucune valeur figée.
//
//  Rôle
//    Racine de l'onglet « Accueil » (`MainTabView`). De haut en bas :
//    salutation et date du jour, raccourcis de réservation par sport,
//    prochaine réservation, cours du club, adhésion, crédits invités et
//    annonces récentes.
//
//  Données
//    - Profil affiché : `AuthController.activeProfile`, c'est-à-dire le compte
//      connecté ou l'enfant sélectionné dans la barre du haut.
//    - Terrains et horaires : `ClubCatalog` (tables `courts` et
//      `club_sport_settings`, terrains fermés par `terrains_interdits`).
//    - Prochaine réservation, cours, annonces, crédits : `HomeStore`, qui les
//      tient à jour en temps réel.
//
//  États
//    Squelettes pendant le premier chargement, carte d'erreur avec
//    « Réessayer » si les terrains n'ont pas pu être lus, cartes vides
//    explicites (aucun terrain, aucune réservation à venir, aucune adhésion).
//    Les sections cours et annonces disparaissent quand elles sont vides.
//
//  Navigation
//    - Tuile d'un sport : onglet « Réserver » sur ce sport.
//    - Carte de prochaine réservation : `ReservationDetailView`, poussé dans
//      la pile de l'accueil (`AppRouter.homePath`).
//    - « Réserver un court » : onglet « Réserver ».
//    - « Voir les formules d'adhésion » : `MembershipFormulasView`.
//
//  Actions et règles
//    Annuler une réservation classique (créateur seulement) ou quitter une
//    partie ouverte, après confirmation. L'annulation passe par
//    `ReservationService.cancel` (mise à jour de `reservations`, autorisée par
//    la RLS au seul créateur ou à un administrateur) ; la sortie de partie par
//    la fonction SQL `leave_open_game`, qui annule toute la partie si c'est
//    l'hôte qui part.
//
//  Points d'attention
//    Pour un enfant sélectionné, l'adhésion n'est pas lisible par le parent :
//    l'accueil affiche « Aucune adhésion active » et des crédits nuls, quelle
//    que soit sa situation réelle (voir `SessionProfile.child`).
//

import SwiftUI

/// Écran d'accueil de l'espace membre.
struct HomeView: View {
    /// Session : profil actif (soi ou un enfant), compte connecté.
    @Environment(AuthController.self) private var auth
    /// Catalogue du club : terrains réservables par sport, heure de fermeture.
    @Environment(ClubCatalog.self) private var catalog
    /// Navigation transverse : ouverture du tunnel de réservation.
    @Environment(AppRouter.self) private var router

    /// Données de l'accueil, chargées et écoutées en temps réel.
    @State private var store = HomeStore()
    /// Réservation dont l'annulation ou la sortie attend la confirmation du
    /// membre ; `nil` quand aucune demande n'est en cours.
    @State private var pendingLeave: MyReservation?
    /// Vrai pendant l'annulation ou la sortie : voile et roue d'attente.
    @State private var isLeaving = false
    /// Message de l'échec d'annulation ou de sortie, affiché en alerte.
    @State private var leaveError: String?

    /// Le compte au nom duquel on agit : le sien, ou celui d'un enfant.
    private var profile: SessionProfile? { auth.activeProfile }

    /// L'accueil ne met en avant que les deux sports principaux, et seulement
    /// s'ils ont un terrain actif : on ne propose jamais de réserver un sport
    /// sans terrain. Le pickleball reste accessible depuis l'onglet Réserver.
    /// Le compte se fait sur les terrains réservables par la personne, hors
    /// terrains qui lui sont fermés.
    private var shortcutSports: [Sport] {
        [.tennis, .padel].filter { catalog.courtCount(for: $0) > 0 }
    }

    /// Colonne défilante des sections, avec la navigation vers le détail, les
    /// chargements, la confirmation de sortie et son éventuelle erreur.
    var body: some View {
        ScrollView {
            // Les sections, dans l'ordre de l'écran.
            VStack(alignment: .leading, spacing: 20) {
                header
                shortcuts
                nextReservationSection
                activitiesSection
                membershipSection
                creditsSection
                announcementsSection

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        // Détail d'une réservation, poussé par la carte de prochaine
        // réservation. Un magasin neuf lui est fourni : il ne sert qu'aux
        // fiches des joueurs.
        .navigationDestination(for: MyReservation.self) { reservation in
            ReservationDetailView(reservation: reservation, store: ReservationsStore())
        }
        // Chargement et écoute temps réel, relancés au changement de profil
        // actif (passage au compte d'un enfant, ou retour).
        .task(id: profile?.id) {
            guard let profile else { return }
            await store.activate(profile: profile)
        }
        // « Tirer pour actualiser » : profil de session (adhésion), catalogue
        // du club, puis contenu de l'accueil.
        .refreshable {
            await auth.refreshSessionProfile()
            await catalog.reload()
            await store.reload()
        }
        // Confirmation avant d'annuler une réservation ou de quitter une
        // partie, avec les libellés propres au cas (voir `MyReservation`).
        .confirmationDialog(
            pendingLeave?.leaveConfirmationTitle ?? "",
            isPresented: leaveConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingLeave
        ) { reservation in
            Button(reservation.leaveActionTitle, role: .destructive) { leave(reservation) }
            Button("Conserver", role: .cancel) {}
        } message: { reservation in
            Text(reservation.leaveConfirmationMessage)
        }
        // Échec de l'annulation ou de la sortie : message de la base ou du
        // réseau.
        .alert("Action impossible", isPresented: leaveErrorBinding) {
            Button("OK") { leaveError = nil }
        } message: {
            Text(leaveError ?? "")
        }
        // Voile léger et roue d'attente pendant l'annulation ou la sortie.
        .overlay {
            if isLeaving {
                Color.black.opacity(0.08).ignoresSafeArea().overlay { ProgressView() }
            }
        }
    }

    // MARK: - En-tête

    /// Salutation par le prénom, date du jour avec l'heure de fermeture, et
    /// pastille verte de l'adhésion quand elle est active.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bonjour \(profile?.greetingName ?? "")")
                .font(.editorial(.largeTitle))
                .foregroundStyle(Brand.navy800)
                .contentTransition(.opacity)

            Text(todayLine)
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            // Pastille « Valide jusqu'au … », absente sans adhésion active.
            if let badge = membershipBadgeText {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                    Text(badge)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Brand.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brand.success.opacity(0.10), in: .capsule)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Jeudi 25 septembre 2026 · le club est ouvert jusqu'à 21 h ». La partie
    /// horaire disparaît si `club_sport_settings` n'a pas encore répondu.
    ///
    /// L'heure retenue est la fermeture la plus tardive parmi tous les sports
    /// (`ClubCatalog.latestClosingMinutes`). Limite connue : la phrase est la
    /// même à toute heure de la journée, y compris après la fermeture.
    private var todayLine: String {
        let date = Date.now.longFrenchDate
        guard let minutes = catalog.latestClosingMinutes else { return date }
        return "\(date) · le club est ouvert jusqu'à \(closingLabel(minutes))"
    }

    /// Heure de fermeture lisible dans une phrase.
    ///
    /// - Parameter minutes: minutes depuis minuit (1 260 pour 21 h).
    /// - Returns: « 21 h », ou « 21 h 30 » quand les minutes ne sont pas nulles.
    private func closingLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        // « 21 h » se lit mieux que « 21 h 00 » dans une phrase.
        return remainder == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, remainder)
    }

    /// Rien si aucune adhésion active : ce n'est pas une erreur, juste un état.
    ///
    /// « Valide jusqu'au 31 août 2027 » quand la date de fin est connue,
    /// « Adhésion à jour » sinon.
    private var membershipBadgeText: String? {
        guard let profile, profile.hasActiveMembership else { return nil }
        guard let fin = profile.activeMembershipPeriod?.fin else { return "Adhésion à jour" }
        return "Valide jusqu'au \(fin.mediumFrenchDate)"
    }

    // MARK: - Raccourcis

    /// Tuiles « Réserver Tennis » et « Réserver Padel », selon l'état du
    /// catalogue du club.
    @ViewBuilder
    private var shortcuts: some View {
        switch catalog.state {
        // Catalogue en cours de chargement : deux tuiles fantômes.
        case .idle, .loading:
            HStack(spacing: 12) {
                SkeletonBlock(height: 132, cornerRadius: Radius.card)
                SkeletonBlock(height: 132, cornerRadius: Radius.card)
            }

        // Lecture des terrains impossible et rien en mémoire : carte d'erreur
        // avec nouvelle tentative.
        case .failed(let message):
            errorCard(title: "Terrains indisponibles", message: message) {
                await catalog.reload()
            }

        // Ni tennis ni padel réservable. Limite connue : un club qui
        // n'aurait que du pickleball verrait aussi ce message, alors que ses
        // terrains sont réservables depuis l'onglet « Réserver ».
        case .loaded where shortcutSports.isEmpty:
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aucun terrain disponible")
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Le club n'a pas encore ouvert de terrain à la réservation.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

        // Une tuile par sport réservable ; le tap ouvre le tunnel de
        // réservation sur ce sport, à sa racine.
        case .loaded:
            HStack(spacing: 12) {
                ForEach(shortcutSports) { sport in
                    SportShortcutTile(sport: sport, courtCount: catalog.courtCount(for: sport)) {
                        Haptics.tap()
                        router.openBooking(for: sport)
                    }
                }
            }
        }
    }

    // MARK: - Prochaine réservation

    /// Section « Votre prochaine réservation » : la carte, un squelette pendant
    /// le premier chargement, ou une carte vide avec « Réserver un court ».
    @ViewBuilder
    private var nextReservationSection: some View {
        section("Votre prochaine réservation") {
            // Une réservation à venir : la carte entière mène au détail.
            if let reservation = store.nextReservation {
                NavigationLink(value: reservation) {
                    NextReservationCard(
                        reservation: reservation,
                        roster: store.roster,
                        onLeave: { pendingLeave = reservation }
                    )
                }
                .buttonStyle(.plain)
            } else if store.phase != .ready {
                // Premier chargement pas encore terminé.
                SkeletonBlock(height: 120, cornerRadius: Radius.card)
            } else {
                // Aucune réservation à venir.
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Brand.textSecondary)
                            Text("Aucune réservation à venir.")
                                .font(.footnote)
                                .foregroundStyle(Brand.textSecondary)
                            Spacer(minLength: 0)
                        }

                        // Ouvre l'onglet « Réserver », à sa racine, sur le
                        // dernier sport consulté.
                        Button("Réserver un court") {
                            Haptics.tap()
                            router.openBooking()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                    }
                }
            }
        }
    }

    // MARK: - Cours

    /// Section « Cours et événements du club » : les premiers cours de la
    /// table `activites`, avec jour, heure, terrain et encadrant. Lecture
    /// seule, sans lien vers l'onglet Cours.
    @ViewBuilder
    private var activitiesSection: some View {
        // La carte disparaît entièrement s'il n'y a aucun cours, plutôt que
        // d'afficher une liste vide.
        if !store.activities.isEmpty {
            section("Cours et événements du club") {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        // Une ligne par cours : nom, puis « Mardi · 19 h 00 ·
                        // Central · encadrant ».
                        ForEach(store.activities) { activity in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.name)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)

                                Text(activity.detailLine(courtName: courtName(activity.courtId)))
                                    .font(.caption)
                                    .foregroundStyle(Brand.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Nom d'un terrain du club, cherché parmi tous les terrains actifs du
    /// catalogue (terrains fermés à la personne compris).
    ///
    /// - Parameter id: terrain (`courts.id`) d'un cours, `nil` s'il n'en a pas.
    /// - Returns: le nom du terrain, ou `nil` s'il est inconnu ou inactif.
    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    // MARK: - Adhésion

    /// Section « Votre adhésion » : validité et formule quand une adhésion est
    /// active, sinon un lien vers les formules du club.
    private var membershipSection: some View {
        section("Votre adhésion") {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    // Adhésion active (statut `a_jour` couvrant aujourd'hui).
                    if let profile, profile.hasActiveMembership {
                        Text(membershipBadgeText ?? "Adhésion à jour")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)

                        // « Formule Annuelle · 180,00 € », montant en euros
                        // (`memberships.montant`).
                        if let details = profile.activeMembershipDetails {
                            Text("Formule \(details.formule) · \(Price.amount(details.montant))")
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                        }
                    } else {
                        // Jamais une date inventée, jamais un blanc.
                        // Toujours le cas pour un enfant sélectionné, dont
                        // l'adhésion n'est pas lisible par le parent.
                        Text("Aucune adhésion active pour l'instant.")
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)

                        // Les formules du club, et l'adhésion depuis le téléphone.
                        // Pas pour un enfant sélectionné : c'est le parent qui paie.
                        if !auth.isActingForChild {
                            NavigationLink {
                                MembershipFormulasView()
                            } label: {
                                Label("Voir les formules d'adhésion", systemImage: "person.text.rectangle")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Brand.navy700)
                            .padding(.top, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Crédits invités

    /// Section « Vos crédits invités » : crédits restants sur la dotation de la
    /// période d'adhésion (« 1 sur 2 restant »). Sans adhésion active, le
    /// solde est nul (« 0 sur 0 »).
    private var creditsSection: some View {
        section("Vos crédits invités") {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    // Gros chiffre des crédits disponibles, puis la dotation.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(store.credits.available)")
                            .font(.numeral(.largeTitle))
                            .foregroundStyle(Brand.navy800)
                            .monospacedDigit()

                        Text("sur \(store.credits.total) restant\(store.credits.available > 1 ? "s" : "")")
                            .font(.subheadline)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    Text("Invitez gratuitement un joueur non membre — inclus dans votre cotisation.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Annonces

    /// Section « Annonces récentes » : les deux dernières annonces actives du
    /// club, avec leur niveau. Absente s'il n'y en a aucune.
    @ViewBuilder
    private var announcementsSection: some View {
        if !store.announcements.isEmpty {
            section("Annonces récentes") {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.announcements) { announcement in
                            VStack(alignment: .leading, spacing: 4) {
                                // Niveau (Information, Important, Urgent), en
                                // couleur pour les deux derniers.
                                BrandChip(
                                    title: announcement.level.displayName,
                                    tint: announcement.level.tint
                                )
                                .fixedSize()

                                Text(announcement.title)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Brand.textPrimary)

                                if !announcement.body.isEmpty {
                                    Text(announcement.body)
                                        .font(.caption)
                                        .foregroundStyle(Brand.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Habillage commun

    /// Section de l'accueil : petit titre en capitales, puis son contenu.
    ///
    /// - Parameters:
    ///   - title: titre de la section.
    ///   - content: contenu de la section.
    /// - Returns: la section mise en forme.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .metaLabelStyle()
            content()
        }
    }

    /// Carte d'erreur avec un bouton « Réessayer ».
    ///
    /// - Parameters:
    ///   - title: titre de la carte.
    ///   - message: explication, déjà rédigée pour le membre.
    ///   - retry: nouvelle tentative, lancée dans une tâche au tap.
    /// - Returns: la carte.
    private func errorCard(
        title: String,
        message: String,
        retry: @escaping () async -> Void
    ) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Button("Réessayer") { Task { await retry() } }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
            }
        }
    }

    // MARK: - Sortie de réservation

    /// Liaison de la demande de confirmation : vraie tant qu'une réservation
    /// attend ; la refermer abandonne la demande.
    private var leaveConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } })
    }

    /// Liaison de l'alerte d'échec : vraie tant qu'un message est posé.
    private var leaveErrorBinding: Binding<Bool> {
        Binding(get: { leaveError != nil }, set: { if !$0 { leaveError = nil } })
    }

    /// Annule la réservation, ou quitte la partie ouverte, après confirmation.
    ///
    /// - Partie ouverte : fonction SQL `leave_open_game` ; un joueur libère sa
    ///   place, l'hôte annule la partie pour tous.
    /// - Réservation classique : `ReservationService.cancel`, qui passe la
    ///   ligne à `annulee` avec la date et l'auteur de l'annulation (la ligne
    ///   est conservée : la restitution du crédit invité en dépend). La RLS
    ///   n'autorise que le créateur ou un administrateur.
    /// Dans les deux cas, le service retire aussi le rappel local de la
    /// réservation (`BookingReminders.cancel`). L'accueil est relu ensuite,
    /// succès ou échec.
    ///
    /// Attention : contrairement à « Mes réservations », l'accueil ne bloque
    /// pas la sortie d'une partie ouverte quand on agit pour un enfant. Or
    /// `leave_open_game` agit toujours pour le compte connecté : l'enfant n'est
    /// pas retiré (aucune erreur n'est signalée), et si le parent est l'hôte de
    /// la partie, c'est toute la partie qui est annulée.
    ///
    /// - Parameter reservation: la réservation confirmée par le membre.
    private func leave(_ reservation: MyReservation) {
        guard let profile else { return }
        pendingLeave = nil
        isLeaving = true

        Task {
            do {
                if reservation.isOpenGame {
                    try await OpenGameService.leave(gameId: reservation.id)
                } else {
                    // L'auteur de l'annulation est toujours le compte
                    // connecté, même quand on agit pour un enfant.
                    try await ReservationService.cancel(
                        reservationId: reservation.id,
                        by: auth.sessionProfile?.id ?? profile.id
                    )
                }
                Haptics.destructive()
            } catch {
                leaveError = error.localizedDescription
                Haptics.failure()
            }
            await store.reload()
            isLeaving = false
        }
    }
}

/// Aperçu Xcode de l'accueil, avec des objets d'environnement vides.
#Preview {
    NavigationStack { HomeView() }
        .environment(AuthController())
        .environment(ClubCatalog())
        .environment(AppRouter())
}
