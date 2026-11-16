//
//  ParticipantsView.swift
//  iClub
//
//  Étape 1 du tunnel : format de jeu et participants.
//
//  Le réservataire est toujours le premier participant, ajouté
//  automatiquement et non supprimable. On ne peut pas continuer tant que la
//  liste n'est pas complète : le bouton annonce ce qui manque.
//
//  Place dans l'application
//    Troisième écran de l'onglet « Réserver », après le créneau
//    (`BookingView`) et le terrain (`CourtPickerView`) ; c'est la première
//    étape de composition de la partie. « Continuer » pousse le récapitulatif
//    (`BookingSummaryView`, via `BookingSummaryRoute`).
//
//  Données
//    Tout l'état est dans le brouillon partagé (`BookingDraft`). À
//    l'affichage, le solde de crédits invités du profil actif est chargé
//    (`GuestCreditService`, tables `guest_credit_allowances` et
//    `reservations`). Les adhérents s'ajoutent par `MemberSearchSheet`
//    (fonction SQL `search_club_members`), les invités par `GuestFormSheet`.
//    Rien n'est écrit en base à cette étape.
//
//  Règles
//    - Format : simple (2 joueurs) ou double (4) ; le padel n'a que le double,
//      affiché comme une information et non comme un choix.
//    - La liste doit être exactement complète pour continuer.
//    - Un adhérent sans adhésion active est signalé en orange.
//    - Un invité consomme un crédit s'il en reste, sinon un supplément.
//
//  Points d'attention
//    Quand on agit pour un enfant, son solde de crédits est toujours nul
//    (adhésion non lisible par le parent) : ses invités passent au supplément.
//

import SwiftUI

/// Route vers le récapitulatif. Le brouillon porte l'état, la route ne sert
/// qu'à l'identité de la destination.
struct BookingSummaryRoute: Hashable {
    /// Terrain choisi (`courts.id`).
    let courtId: UUID
    /// Créneau choisi.
    let slot: TimeSlot
}

/// Écran « Joueurs » : format de jeu, liste des participants, crédits
/// invités, et bouton « Continuer » fixé en bas.
struct ParticipantsView: View {
    /// Sport, jour et créneau choisis.
    let route: BookingSlotRoute
    /// Terrain choisi, relu dans le catalogue par `BookingView`.
    let court: Court
    /// Brouillon du tunnel, déjà initialisé par `CourtPickerView`.
    let draft: BookingDraft

    /// Session : profil actif (crédits, recherche, message d'adhésion).
    @Environment(AuthController.self) private var auth
    /// Navigation : pile de l'onglet « Réserver ».
    @Environment(AppRouter.self) private var router

    /// Vrai pendant que la recherche d'adhérent est ouverte.
    @State private var isSearchingMember = false
    /// Vrai pendant que le formulaire d'invité est ouvert.
    @State private var isAddingGuest = false

    /// Formats proposés pour ce sport : un seul en padel.
    private var formats: [GameFormat] { GameFormat.options(for: route.sport) }

    /// Colonne défilante (en-tête, format, joueurs, crédits) et barre
    /// « Continuer » fixée en bas, avec les deux feuilles d'ajout.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                formatSection
                participantsSection
                creditsNote
                // Réserve la place de la barre « Continuer » fixée en bas.
                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Joueurs")
        .navigationBarTitleDisplayMode(.inline)
        // Barre « Continuer », toujours visible au-dessus du contenu.
        .safeAreaInset(edge: .bottom) { continueBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Recherche d'un adhérent du club ; ceux déjà listés sont écartés.
        .sheet(isPresented: $isSearchingMember) {
            if let profile = auth.activeProfile {
                MemberSearchSheet(
                    clubId: court.clubId,
                    myProfileId: profile.id,
                    sport: route.sport,
                    excluded: draft.takenProfileIds,
                    onSelect: { draft.add(member: $0) }
                )
            }
        }
        // Ajout d'un invité, avec les crédits encore disponibles.
        .sheet(isPresented: $isAddingGuest) {
            GuestFormSheet(creditsRemaining: draft.creditsRemaining) { prenom, nom, payer in
                draft.add(guestPrenom: prenom, nom: nom, payer: payer)
            }
        }
        // Solde de crédits invités, chargé à l'affichage sans bloquer l'écran.
        .task {
            guard let profile = auth.activeProfile else { return }
            await draft.loadCredits(profile: profile)
        }
    }

    // MARK: - En-tête

    /// Date complète, puis « Terrain · horaire ».
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.date.longFrenchDate)
                .metaLabelStyle()

            Text("\(court.nom) · \(route.slot.label)")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Format

    /// Section « Format » : un bandeau d'information quand un seul format
    /// existe, sinon une pastille par format.
    @ViewBuilder
    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .metaLabelStyle()

            if formats.count == 1, let only = formats.first {
                // Padel : l'information, pas un choix.
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(route.sport.accent)
                    Text("\(only.displayName) · \(only.detail)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    route.sport.accent.opacity(0.10),
                    in: .rect(cornerRadius: Radius.chip, style: .continuous)
                )
            } else {
                // Tennis et pickleball : simple ou double, au choix.
                HStack(spacing: 8) {
                    ForEach(formats, id: \.self) { format in
                        formatChip(format)
                    }
                }
            }
        }
    }

    /// Pastille d'un format (« Simple, 2 joueurs »). La choisir ajuste la
    /// liste : passer en simple retire les joueurs en trop, par la fin.
    ///
    /// - Parameter format: format représenté.
    /// - Returns: le bouton de la pastille.
    private func formatChip(_ format: GameFormat) -> some View {
        let isSelected = draft.format == format

        return Button {
            draft.setFormat(format)
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                Text(format.displayName)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(format.detail)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(isSelected ? Color.white : route.sport.accent)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? route.sport.accent : route.sport.accent.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Participants

    /// Section « Joueurs » : compteur « 2 / 4 », une carte par joueur, puis
    /// les boutons d'ajout tant qu'il reste de la place.
    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Joueurs")
                    .metaLabelStyle()
                Spacer(minLength: 0)
                Text("\(draft.participants.count) / \(draft.capacity)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .monospacedDigit()
            }

            ForEach(draft.participants) { participant in
                participantRow(participant)
            }

            // Boutons d'ajout, masqués quand la liste est pleine.
            if draft.hasRoom {
                HStack(spacing: 8) {
                    addButton(title: "Adhérent", systemImage: "magnifyingglass") {
                        isSearchingMember = true
                    }
                    addButton(title: "Invité", systemImage: "person.badge.plus") {
                        isAddingGuest = true
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Carte d'un joueur : photo ou initiales, nom, rôle (« Réservataire »,
    /// « Adhérent », « Sans adhésion active », « Invité · crédit »...), et
    /// bouton de retrait sauf pour le réservataire.
    ///
    /// - Parameter participant: joueur affiché.
    /// - Returns: la carte.
    private func participantRow(_ participant: BookingParticipant) -> some View {
        HStack(spacing: 12) {
            MemberAvatar(url: participant.avatarUrl, initials: participant.initials, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)

                Text(participant.roleLabel)
                    .font(.caption)
                    .foregroundStyle(roleTint(participant))
            }

            Spacer(minLength: 0)

            // Retrait possible pour tous, sauf le réservataire.
            if participant.isRemovable {
                Button {
                    draft.remove(participant)
                    Haptics.tap()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.textSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retirer \(participant.displayName)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    /// Couleur du rôle : bleu marine pour le réservataire, orange pour un
    /// adhérent sans adhésion active, gris sinon.
    ///
    /// - Parameter participant: joueur concerné.
    /// - Returns: la couleur du libellé de rôle.
    private func roleTint(_ participant: BookingParticipant) -> Color {
        switch participant.kind {
        case .owner: Brand.navy700
        case .member: participant.hasActiveMembership ? Brand.textSecondary : Brand.warning
        case .guest: Brand.textSecondary
        }
    }

    /// Bouton d'ajout en pointillés (« Adhérent » ou « Invité »).
    ///
    /// - Parameters:
    ///   - title: libellé du bouton.
    ///   - systemImage: pictogramme.
    ///   - action: ouverture de la feuille correspondante.
    /// - Returns: le bouton.
    private func addButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Brand.navy700)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .strokeBorder(Brand.navy700.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Crédits

    /// Rappel des crédits invités : « 1 crédit invité sur 2 » quand une
    /// dotation existe, sinon, pour un profil sans adhésion active, une
    /// explication du supplément. Rien d'autre tant que le solde n'est pas
    /// chargé.
    @ViewBuilder
    private var creditsNote: some View {
        if draft.credits.total > 0 {
            HStack(spacing: 10) {
                Image(systemName: "ticket")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.textSecondary)

                Text("\(draft.creditsRemaining) crédit\(draft.creditsRemaining > 1 ? "s" : "") invité sur \(draft.credits.total)")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Brand.textSecondary.opacity(0.08),
                in: .rect(cornerRadius: Radius.chip, style: .continuous)
            )
        } else if auth.activeProfile?.hasActiveMembership == false {
            // Sans adhésion active (et toujours pour un enfant sélectionné).
            InlineMessage(
                kind: .info,
                message: "Sans adhésion active, tu n'as pas de crédit invité : les invités règlent le supplément."
            )
        }
    }

    // MARK: - Continuer

    /// Barre du bas : « Continuer » vers le récapitulatif, inactif tant que la
    /// liste n'est pas complète.
    private var continueBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: continueTitle,
                systemImage: draft.isComplete ? "arrow.right" : nil
            ) {
                router.bookingPath.append(
                    BookingSummaryRoute(courtId: court.id, slot: route.slot)
                )
            }
            .disabled(!draft.isComplete)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// « Continuer », ou le nombre de joueurs qui manquent, accordé.
    private var continueTitle: String {
        guard !draft.isComplete else { return "Continuer" }
        let missing = draft.missingCount
        return "Continuer — il manque \(missing) joueur\(missing > 1 ? "s" : "")"
    }
}
