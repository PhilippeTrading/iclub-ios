//
//  ReservationsView.swift
//  iClub
//
//  Onglet « Réservations » : à venir puis passées, les annulées marquées
//  visuellement sans être masquées. Savoir qu'on a annulé fait partie de
//  l'information.
//
//  Place dans l'application
//    Écran « Réservations » (historique), poussé dans la pile de l'onglet
//    « Réserver » par le bouton horloge de la barre (`ReservationHistoryRoute`)
//    ou par le tap sur un rappel de réservation
//    (`AppRouter.openReservationHistory`). Une carte ouvre le détail
//    (`ReservationDetailView`).
//
//  Données
//    `ReservationsStore` : réservations créées par le profil actif ou
//    auxquelles il participe (tables `reservations` et
//    `reservation_participants`), avec les photos des joueurs
//    (`get_club_roster_info`). Pour un enfant sélectionné, ce sont les
//    siennes.
//
//  États
//    Squelettes au premier chargement, carte d'erreur avec « Réessayer »,
//    écran vide « Aucune réservation », puis les sections « À venir » et
//    « Passées ».
//
//  Actions et règles, et ce que la base revérifie
//    - Réservation classique : seul son créateur l'annule
//      (`ReservationService.cancel`, mise à jour de `reservations` ; la RLS
//      `reservations_update` réserve cette écriture au créateur ou à un
//      administrateur).
//    - Partie ouverte : tout joueur la quitte, l'hôte l'annule pour tous
//      (fonction SQL `leave_open_game`, qui n'agit que pour le compte
//      connecté : impossible donc pour un enfant, ce que l'écran explique).
//    - Aucune condition de date : une réservation passée reste annulable.
//

import SwiftUI

/// Liste des réservations du profil actif, à venir puis passées, avec
/// annulation ou sortie depuis chaque carte.
struct ReservationsView: View {
    /// Session : profil actif (dont on lit les réservations), compte connecté
    /// (auteur de l'annulation).
    @Environment(AuthController.self) private var auth

    /// Magasin des réservations, partagé avec l'écran de détail.
    @State private var store = ReservationsStore()

    /// Réservation dont l'annulation attend confirmation.
    @State private var pendingCancel: MyReservation?
    /// Vrai pendant l'annulation ou la sortie : voile et roue d'attente.
    @State private var isCancelling = false
    /// Message de l'échec, affiché en alerte.
    @State private var cancelError: String?

    /// Selon l'état du magasin, erreur, squelettes, écran vide ou les deux
    /// sections ; puis la confirmation et l'alerte d'échec.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Lecture impossible et rien à montrer.
                if case .failed(let message) = store.phase {
                    errorState(message)
                } else if store.reservations.isEmpty, store.phase != .ready {
                    // Premier chargement en cours.
                    skeletons
                } else if store.reservations.isEmpty {
                    // Aucune réservation, ni à venir ni passée.
                    PhasePlaceholder(
                        systemImage: "calendar",
                        title: "Aucune réservation",
                        message: "Tes parties à venir et passées apparaîtront ici.",
                        accent: Brand.navy700
                    )
                    .padding(.horizontal, -20)
                } else {
                    // Les deux sections ; une section vide n'est pas affichée.
                    section("À venir", store.upcoming)
                    section("Passées", store.past)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Réservations")
        // Détail d'une réservation, avec le magasin partagé.
        .navigationDestination(for: MyReservation.self) { reservation in
            ReservationDetailView(reservation: reservation, store: store)
        }
        // Les réservations du compte actif : un parent voit celles de l'enfant
        // sélectionné.
        .task(id: auth.activeProfile?.id) {
            guard let profile = auth.activeProfile else { return }
            await store.load(clubId: profile.clubId, profileId: profile.id)
        }
        .refreshable { await store.reload() }
        // Confirmation, avec rappel du terrain, du jour et de l'horaire, puis
        // la conséquence propre au cas (voir `MyReservation`).
        .confirmationDialog(
            pendingCancel?.leaveConfirmationTitle ?? "",
            isPresented: cancelConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingCancel
        ) { reservation in
            Button(reservation.leaveActionTitle, role: .destructive) { cancel(reservation) }
            Button("Conserver", role: .cancel) {}
        } message: { reservation in
            Text("\(reservation.courtName) · \(reservation.date.longFrenchDate) · \(reservation.slot.label)\n\(reservation.leaveConfirmationMessage)")
        }
        // Échec de l'annulation ou de la sortie, ou refus pour un enfant.
        .alert("Action impossible", isPresented: cancelErrorBinding) {
            Button("OK") { cancelError = nil }
        } message: {
            Text(cancelError ?? "")
        }
        // Voile léger et roue d'attente pendant l'envoi.
        .overlay {
            if isCancelling {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .overlay { ProgressView() }
            }
        }
    }

    // MARK: - Annulation

    /// Réservation classique : seul le créateur peut annuler. Un simple
    /// participant ne peut pas annuler la réservation d'un autre.
    ///
    /// Partie ouverte : **tout joueur** peut sortir. C'est indispensable : une
    /// partie complète disparaît de « Parties ouvertes », et sans ce bouton un
    /// joueur serait piégé dans une partie dont il ne peut plus sortir.
    /// L'hôte, lui, annule la partie entière.
    ///
    /// Volontairement sans test sur la date : une réservation passée reste
    /// annulable, ce qui permet de corriger une partie qui n'a pas eu lieu.
    ///
    /// - Parameter reservation: réservation de la carte.
    /// - Returns: vrai si la carte doit porter un bouton « Annuler » ou
    ///   « Quitter ».
    private func canCancel(_ reservation: MyReservation) -> Bool {
        guard !reservation.isCancelled else { return false }
        return reservation.isOwner || reservation.isOpenGame
    }

    /// Liaison de la demande de confirmation : vraie tant qu'une réservation
    /// attend ; la refermer abandonne la demande.
    private var cancelConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingCancel != nil },
            set: { if !$0 { pendingCancel = nil } }
        )
    }

    /// Liaison de l'alerte d'échec : vraie tant qu'un message est posé.
    private var cancelErrorBinding: Binding<Bool> {
        Binding(
            get: { cancelError != nil },
            set: { if !$0 { cancelError = nil } }
        )
    }

    /// Annule la réservation, ou quitte la partie ouverte, après confirmation,
    /// puis recharge la liste.
    ///
    /// - Parameter reservation: réservation confirmée par le membre.
    private func cancel(_ reservation: MyReservation) {
        guard let profile = auth.sessionProfile else { return }
        pendingCancel = nil
        // Quitter une partie n'agit que pour le compte connecté : impossible
        // pour un enfant tant que la base ne le permet pas.
        if reservation.isOpenGame && auth.isActingForChild {
            cancelError = "Pour retirer votre enfant de cette partie, contactez le club."
            return
        }
        isCancelling = true

        Task {
            do {
                if reservation.isOpenGame {
                    // Une seule fonction couvre les deux cas : elle retire le
                    // participant, ou annule la partie si l'appelant est l'hôte.
                    try await OpenGameService.leave(gameId: reservation.id)
                } else {
                    // Réservation classique : passage à `annulee`, avec la
                    // date et l'auteur (le compte connecté, même pour un
                    // enfant).
                    try await ReservationService.cancel(
                        reservationId: reservation.id,
                        by: profile.id
                    )
                }
                Haptics.destructive()
                // Le crédit invité éventuel est restitué de lui-même : le solde
                // est recalculé, jamais stocké.
                // (Seulement si l'annulation intervient au moins deux heures
                // avant le début : voir `CreditUsageRow`.)
                await store.reload()
            } catch {
                cancelError = error.localizedDescription
                Haptics.failure()
            }
            isCancelling = false
        }
    }

    // MARK: - Sections

    /// Une section titrée (« À venir » ou « Passées ») avec ses cartes ;
    /// rien si la liste est vide.
    ///
    /// - Parameters:
    ///   - title: titre de la section.
    ///   - items: réservations de la section, déjà triées.
    /// - Returns: la section.
    @ViewBuilder
    private func section(_ title: String, _ items: [MyReservation]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .metaLabelStyle()

                ForEach(items) { reservation in
                    let isCancellable = canCancel(reservation)

                    // Le bouton d'annulation est posé *à côté* du lien, pas
                    // dedans : un `Button` imbriqué dans un `NavigationLink`
                    // laisse le geste se disputer entre les deux, et le tap
                    // partirait vers l'écran de détail.
                    ZStack(alignment: .topTrailing) {
                        NavigationLink(value: reservation) {
                            ReservationCard(
                                reservation: reservation,
                                roster: store.roster,
                                reservesCancelSlot: isCancellable
                            )
                        }
                        .buttonStyle(.plain)

                        // Bouton « Annuler » (créateur, hôte) ou « Quitter »
                        // (simple joueur d'une partie ouverte), qui ouvre la
                        // confirmation.
                        if isCancellable {
                            Button {
                                pendingCancel = reservation
                                Haptics.tap()
                            } label: {
                                CancelChipLabel(title: reservation.isOpenGame
                                    ? (reservation.isOwner ? "Annuler" : "Quitter")
                                    : "Annuler")
                            }
                            .buttonStyle(.plain)
                            .disabled(isCancelling)
                            // Aligné sur la marge interne de la carte, pour
                            // retomber pile sur le gabarit réservé.
                            .padding(14)
                            // Limite connue : le libellé VoiceOver dit
                            // « Annuler » même quand le bouton affiche « Quitter ».
                            .accessibilityLabel(
                                "Annuler la réservation du \(reservation.date.mediumFrenchDate) à \(reservation.slot.startLabel)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - États

    /// Quatre cartes fantômes pendant le premier chargement.
    private var skeletons: some View {
        VStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(height: 92, cornerRadius: Radius.inner)
            }
        }
    }

    /// Carte « Réservations indisponibles » avec un bouton « Réessayer ».
    ///
    /// - Parameter message: cause de l'échec, prête à afficher.
    /// - Returns: la carte.
    private func errorState(_ message: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Réservations indisponibles")
                    .font(.editorial(.headline))
                    .foregroundStyle(Brand.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Button("Réessayer") {
                    Task { await store.reload() }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - Carte

/// Libellé du bouton d'annulation.
///
/// Extrait pour servir deux fois : au bouton réel, et de gabarit invisible dans
/// la carte. C'est ce qui garantit que le bouton posé par-dessus occupe
/// exactement la place laissée libre, sans mesure recopiée à la main.
struct CancelChipLabel: View {
    /// « Annuler » pour une réservation ou pour l'hôte d'une partie,
    /// « Quitter » pour un simple joueur d'une partie ouverte.
    var title = "Annuler"

    /// Pastille rouge de la taille de son contenu.
    var body: some View {
        // Croix et libellé, en rouge sur fond rouge pâle, avec un filet.
        HStack(spacing: 5) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(Brand.error)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Brand.error.opacity(0.10),
            in: .rect(cornerRadius: Radius.chip, style: .continuous)
        )
        .overlay {
            RoundedRectangle.squircle(Radius.chip)
                .strokeBorder(Brand.error.opacity(0.30), lineWidth: 0.5)
        }
        .fixedSize()
    }
}

/// Carte d'une réservation dans la liste : pictogramme du sport, terrain et
/// sa description, statut (ou place du bouton d'annulation), date, horaire
/// et photos des joueurs.
struct ReservationCard: View {
    /// Réservation présentée.
    let reservation: MyReservation
    /// Photos des participants, indexées par profil. Vide tant que le second
    /// appel n'est pas revenu : les vignettes affichent alors les initiales.
    var roster: [UUID: RosterInfoRow] = [:]
    /// `true` quand l'annulation est possible : la carte laisse alors la place
    /// du bouton libre au lieu d'afficher la pastille de statut. Pour une
    /// réservation déjà annulée, ou une réservation classique dont je ne suis
    /// pas le créateur, c'est la pastille qui reste la bonne information.
    /// (Une réservation passée encore annulable garde la place du bouton.)
    var reservesCancelSlot = false

    /// Carte sur deux lignes, estompée si la réservation est annulée.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Ligne du haut : sport, terrain, statut ou place du bouton.
            HStack(spacing: 12) {
                Image(systemName: reservation.sport?.symbolName ?? "sportscourt")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reservation.courtName)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)

                    Text(reservation.courtDetail)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Gabarit invisible du bouton posé par-dessus par la liste,
                // sinon la pastille de statut.
                if reservesCancelSlot {
                    CancelChipLabel(title: reservation.isOpenGame
                        ? (reservation.isOwner ? "Annuler" : "Quitter")
                        : "Annuler").hidden()
                } else {
                    BrandChip(title: reservation.statusLabel, tint: statusTint)
                }
            }

            // Ligne du bas : date, horaire, photos des joueurs.
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.textSecondary)

                Text("\(reservation.date.mediumFrenchDate) · \(reservation.slot.label)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Brand.textPrimary)

                Spacer(minLength: 0)

                participantAvatars
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
        // Une réservation annulée reste lisible mais nettement en retrait.
        .opacity(reservation.isCancelled ? 0.55 : 1)
    }

    /// Mini-photos des participants, légèrement chevauchées.
    ///
    /// La photo remplace les initiales dès qu'elle existe. Un invité, qui n'a
    /// pas de profil au club, garde ses initiales, de même qu'un membre qui
    /// n'a jamais changé sa photo. Au plus quatre photos.
    private var participantAvatars: some View {
        HStack(spacing: -8) {
            ForEach(reservation.participants.prefix(4)) { participant in
                MemberAvatar(
                    url: participant.profileId
                        .flatMap { roster[$0]?.avatarUrl }
                        .flatMap(URL.init(string:)),
                    initials: participant.initials,
                    size: 24
                )
                .overlay {
                    Circle().strokeBorder(Brand.surface, lineWidth: 1.5)
                }
            }
        }
    }

    /// Couleur du sport, grise pour une réservation annulée.
    private var accent: Color {
        reservation.isCancelled ? Brand.textSecondary : (reservation.sport?.accent ?? Brand.navy700)
    }

    /// Teinte de la pastille de statut : rouge si annulée, bleu marine si
    /// payée, vert sinon. Attention : « payée » repose sur
    /// `statut_paiement = 'paye'`, valeur que la base n'emploie plus (voir
    /// NextReservationCard.swift).
    private var statusTint: Color {
        if reservation.isCancelled { return Brand.error }
        return reservation.isPaid ? Brand.navy700 : Brand.success
    }
}

/// Aperçu Xcode de quatre cartes : à venir avec trois joueurs, simple
/// participant, annulée, et joueur d'une partie ouverte (« Quitter »).
#Preview {
    // Le premier profil fictif reçoit une photo réellement présente dans le
    // stockage Supabase (bucket public `avatars`), le second aucune : la
    // vignette doit montrer une photo pour l'un et les initiales pour l'autre.
    // Attention : l'aperçu charge donc un fichier du stockage de production.
    let withPhotoId = UUID(uuidString: "14E3E0F6-AAE9-4C56-9F54-899B1D731F7F")!
    let withoutPhotoId = UUID()

    /// Fabrique une fiche joueur fictive, décodée comme la réponse de
    /// `get_club_roster_info`.
    func rosterEntry(_ id: UUID, _ prenom: String, _ avatar: String?) -> RosterInfoRow {
        var json = "{\"profile_id\":\"" + id.uuidString + "\""
        json += ",\"prenom\":\"" + prenom + "\",\"nom\":\"Test\""
        json += ",\"avatar_url\":" + (avatar.map { "\"" + $0 + "\"" } ?? "null")
        json += ",\"age\":30,\"classement_tennis\":\"15/2\",\"classement_padel\":null}"
        return try! JSONDecoder().decode(RosterInfoRow.self, from: Data(json.utf8))
    }

    // Adresse publique de la photo du premier profil, puis les deux fiches.
    let avatarURL = "https://wjjplbkvvomdxlgqrcjq.supabase.co/storage/v1/object/public/avatars/14e3e0f6-aae9-4c56-9f54-899b1d731f7f/avatar.png"
    let roster = [
        withPhotoId: rosterEntry(withPhotoId, "Camille", avatarURL),
        withoutPhotoId: rosterEntry(withoutPhotoId, "Marie", nil),
    ]

    /// Fabrique une réservation fictive de tennis à 14 h, dans `days` jours.
    func reservation(
        court: String,
        days: Int,
        cancelled: Bool = false,
        owner: Bool = true,
        openGame: Bool = false,
        players: Int = 2
    ) -> MyReservation {
        MyReservation(
            id: UUID(),
            date: Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now,
            slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 60),
            sport: .tennis,
            courtName: court,
            surface: "Terre battue",
            isIndoor: false,
            isCancelled: cancelled,
            isPaid: false,
            isOwner: owner,
            createdBy: UUID(),
            isOpenGame: openGame,
            format: .simple,
            participants: [
                .init(profileId: withoutPhotoId, displayName: "Marie Dupont"),
                .init(profileId: withPhotoId, displayName: "Camille Roux"),
                // Invité : pas de profil au club, donc jamais de photo.
                .init(profileId: nil, displayName: "Léa Martin"),
            ].prefix(max(1, players)).map { $0 }
        )
    }

    // Cartes de l'aperçu, chacune avec son indicateur « annulable ».
    let rows: [(MyReservation, Bool)] = [
        // Trois participants : sans photo, avec photo, et un invité.
        (reservation(court: "Central", days: 2, players: 3), true),
        (reservation(court: "Tennis 3", days: 2, owner: false), false),
        (reservation(court: "Terbal A", days: 4, cancelled: true), false),
        // Partie ouverte où je ne suis que joueur : « Quitter ».
        (reservation(court: "Padel 1", days: 3, owner: false, openGame: true, players: 2), true),
    ]

    return ScrollView {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ZStack(alignment: .topTrailing) {
                    ReservationCard(reservation: row.0, roster: roster, reservesCancelSlot: row.1)
                    if row.1 {
                        Button {} label: { CancelChipLabel() }
                            .buttonStyle(.plain)
                            .padding(14)
                    }
                }
            }
        }
        .padding(20)
    }
    .background(Brand.background)
}
