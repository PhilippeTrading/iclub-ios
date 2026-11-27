//
//  BookingSummaryView.swift
//  iClub
//
//  Étape 2 du tunnel de réservation : récapitulatif du créneau et du terrain,
//  liste des joueurs, détail du montant, mode de paiement, conditions
//  d'annulation, puis confirmation.
//
//  Le bloc de paiement n'apparaît que si le total est supérieur à zéro : une
//  partie entre adhérents à jour ne déclenche aucun paiement, et le bouton
//  final dit simplement « Confirmer la réservation ».
//
//  Aucune intégration bancaire n'est branchée : les trois modes sont des
//  intentions enregistrées en base, que le club traite ensuite.
//
//  Place dans l'application
//    Quatrième écran de l'onglet « Réserver », après le créneau
//    (`BookingView`), le terrain (`CourtPickerView`) et les joueurs
//    (`ParticipantsView`, étape 1). La destination est déclarée dans
//    `BookingView` (`BookingSummaryRoute`). Une réservation enregistrée
//    remplace toute la pile du tunnel par l'écran de succès
//    (`BookingConfirmedView`, route `BookingConfirmation`).
//
//  Données
//    Tout l'état du tunnel vient du brouillon partagé (`BookingDraft`), qui
//    ne change pas pendant que cet écran est affiché. Lectures propres à
//    l'écran : le risque de pluie (`RainReserveService.risk`, fonction SQL
//    `cours_exterieurs_concurrents`) et, pour un enfant, ses terrains fermés
//    (`PlanningService.forbiddenCourts`, fonction SQL `terrains_interdits`).
//    L'écriture passe par `ReservationService.confirm` : une ligne de
//    `reservations`, puis ses joueurs dans `reservation_participants`.
//
//  Règles métier
//    - Montant : somme des suppléments des invités qui ne prennent pas de
//      crédit ; les adhérents sont inclus dans leur cotisation, un invité sur
//      crédit est gratuit (`BookingDraft.total`).
//    - Confirmation possible seulement quand la liste des joueurs est
//      complète, les conditions d'annulation acceptées et le terrain connu
//      (`BookingDraft.canConfirm`).
//    - Réservation au nom d'un enfant : ses terrains fermés sont vérifiés ici,
//      avant tout envoi, parce que la base contrôle les groupes de l'auteur
//      de la réservation (le parent connecté), pas ceux de l'enfant.
//    - Sous réserve de pluie (règle du web du 30 octobre 2026) : sur un
//      terrain couvert réservé pendant qu'un cours ou un stage se tient en
//      extérieur sur le même sport, un avis s'affiche sous le récapitulatif
//      et une fenêtre demande l'accord de l'adhérent avant d'envoyer quoi
//      que ce soit. C'est la base qui marque la réservation
//      (`reservations.sous_reserve_pluie`, déclencheur `sous_reserve_pluie`),
//      par la même fonction que celle qui fournit l'avis : l'app n'envoie
//      jamais ce marqueur. Textes et formats dans `RainReserve.swift`.
//
//  Effets de bord
//    Écritures en base (réservation et joueurs), retour haptique,
//    reprogrammation des rappels locaux (`BookingReminders`), relecture des
//    terrains fermés après un refus de la base, navigation du tunnel.
//
//  Points d'attention
//    - Attention : une réservation avec un montant à régler (invité au
//      supplément) est refusée par la base. L'app écrit un état et un mode
//      de paiement que les contraintes de la table n'acceptent plus, et
//      l'erreur technique s'affiche telle quelle (voir `ReservationService`
//      et `Models/Reservation.swift`).
//    - Limite connue, la même que sur le web : l'avis de pluie arrive après
//      l'affichage, par un appel réseau. Un appui sur le bouton final avant
//      la réponse envoie la réservation sans avis ni fenêtre, et la base la
//      marque quand même sous réserve de pluie. Une erreur de l'appel vaut
//      « aucun risque » : la réservation reste possible, sans avis.
//    - L'acceptation des conditions d'annulation n'est pas enregistrée en
//      base : elle ne fait qu'autoriser le bouton.
//
//  Fil d'exécution
//    Vue SwiftUI, sur l'acteur principal ; les appels réseau sont lancés dans
//    des tâches asynchrones (`Task`, `.task(id:)`).
//

import SwiftUI

/// Récapitulatif d'une réservation de terrain, juste avant son envoi.
struct BookingSummaryView: View {
    /// Brouillon du tunnel, partagé par tous ses écrans : terrain, jour,
    /// créneau, sport, format, joueurs, crédits, mode de paiement et
    /// acceptation des conditions.
    let draft: BookingDraft

    /// Session : compte connecté, enfant au nom de qui l'on agit.
    @Environment(AuthController.self) private var auth
    /// Catalogue du club, dont les terrains fermés à relire après un refus.
    @Environment(ClubCatalog.self) private var catalog
    /// Piles de navigation des onglets (ici, celle du tunnel de réservation).
    @Environment(AppRouter.self) private var router

    /// Vrai pendant l'envoi : le bouton tourne et ne répond plus.
    @State private var isConfirming = false
    /// Dernier échec à afficher sous le formulaire, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Vrai quand l'échec est un créneau pris entre-temps : on renvoie alors
    /// l'utilisateur vers la liste rafraîchie plutôt que de le laisser sur place.
    @State private var slotWasTaken = false
    /// Cours en extérieur qui pourrait reprendre ce terrain couvert s'il pleut.
    /// `nil` : terrain extérieur, aucun cours à cette heure-là, réponse pas
    /// encore arrivée, ou appel en échec.
    @State private var rainRisk: RainRisk?
    /// Vrai pendant que la fenêtre « Réserver sous réserve de pluie ? » est
    /// ouverte.
    @State private var asksRainConfirmation = false

    /// L'écran : cartes empilées dans un défilement, bouton de confirmation
    /// fixé en bas, fenêtres de créneau pris et de pluie.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Jour, créneau, terrain et format.
                recapCard

                // Avis de pluie, seulement sur un terrain couvert pendant un
                // cours en extérieur, sous le récapitulatif comme sur le web.
                if let rainRisk {
                    RainReserveNotice(risk: rainRisk)
                }

                // Joueurs, puis le montant ligne par ligne.
                participantsCard
                amountCard

                // Le choix du mode de paiement n'a de sens que si quelque
                // chose est dû.
                if draft.requiresPayment {
                    paymentSection
                }

                // Conditions d'annulation, obligatoires pour confirmer.
                termsToggle

                // Échec de l'envoi : refus de la base, réseau, terrain fermé.
                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }

                // Marge sous la dernière carte : le bouton fixé en bas ne doit
                // pas la recouvrir.
                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Récapitulatif")
        .navigationBarTitleDisplayMode(.inline)
        // Bouton de confirmation, toujours visible au-dessus du bas d'écran.
        .safeAreaInset(edge: .bottom) { confirmBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Créneau pris par quelqu'un d'autre entre l'affichage et l'envoi.
        .alert("Créneau indisponible", isPresented: $slotWasTaken) {
            Button("Choisir un autre créneau") {
                // Retour à la racine du tunnel : la liste des créneaux est
                // abonnée au temps réel, elle est déjà à jour.
                router.bookingPath = NavigationPath()
            }
        } message: {
            Text(ReservationError.slotAlreadyTaken.localizedDescription)
        }
        // Sous réserve de pluie : l'adhérent l'accepte avant tout envoi.
        // « Non » ramène au récapitulatif, rien n'est réservé. Titre, boutons
        // et message sont ceux du web (`ReservationTunnel.tsx`) ; le message
        // est le second paragraphe de l'avis, mot pour mot.
        .alert("Réserver sous réserve de pluie ?", isPresented: $asksRainConfirmation, presenting: rainRisk) { _ in
            Button("Oui, je réserve") { confirm() }
            Button("Non", role: .cancel) {}
        } message: { risk in
            Text(risk.consequence)
        }
        // Demande du risque de pluie à l'affichage, et de nouveau si le
        // terrain, le jour ou l'heure de début changent (clé de la tâche).
        // Sans terrain, pas de risque.
        .task(id: RainRiskKey(courtId: draft.court?.id, day: SupabaseDate.day(from: draft.date), start: draft.slot.startMinutes)) {
            guard let court = draft.court else { rainRisk = nil; return }
            rainRisk = await RainReserveService.risk(court: court, date: draft.date, slot: draft.slot)
        }
    }

    // MARK: - Récapitulatif

    /// Carte du haut : jour, créneau, terrain avec sa description, format et
    /// nombre de joueurs. Rien n'est affiché tant que le brouillon n'a pas de
    /// terrain.
    @ViewBuilder
    private var recapCard: some View {
        if let court = draft.court {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    // Jour en toutes lettres, puis les heures du créneau.
                    Text(draft.date.longFrenchDate)
                        .metaLabelStyle()

                    Text(draft.slot.label)
                        .font(.editorial(.title2))
                        .foregroundStyle(Brand.navy800)

                    Divider().opacity(0.4)

                    // Pastille du sport, nom et description du terrain,
                    // format et capacité (« Double · 4 »).
                    HStack(spacing: 12) {
                        Image(systemName: draft.sport.symbolName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(draft.sport.accent)
                            .frame(width: 36, height: 36)
                            .background(draft.sport.accent.opacity(0.12), in: .circle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(court.nom)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(court.descriptionLabel)
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                        }

                        Spacer(minLength: 0)

                        BrandChip(
                            title: "\(draft.format.displayName) · \(draft.capacity)",
                            tint: draft.sport.accent
                        )
                    }
                }
            }
        }
    }

    // MARK: - Participants

    /// Les joueurs, dans l'ordre du brouillon (le réservataire en premier),
    /// avec leur photo et leur rôle (« Réservataire », « Adhérent »,
    /// « Invité · crédit »...).
    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Joueurs")
                .metaLabelStyle()

            // Une ligne par joueur : photo ou initiales, nom, rôle.
            ForEach(draft.participants) { participant in
                HStack(spacing: 12) {
                    MemberAvatar(url: participant.avatarUrl, initials: participant.initials, size: 34)

                    Text(participant.displayName)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)

                    Spacer(minLength: 0)

                    Text(participant.roleLabel)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard(cornerRadius: Radius.chip)
            }
        }
    }

    // MARK: - Détail du montant

    /// Carte du montant : une ligne par joueur, puis le total à régler, en
    /// vert quand il est nul.
    private var amountCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Montant")
                    .metaLabelStyle()

                ForEach(draft.participants) { participant in
                    amountRow(participant)
                }

                Divider().opacity(0.4)

                // Total : somme des suppléments (`BookingDraft.total`).
                HStack {
                    Text("Total à régler")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                    Text(Price.amount(draft.total))
                        .font(.numeral(.title3))
                        .foregroundStyle(draft.requiresPayment ? Brand.navy800 : Brand.success)
                }
            }
        }
    }

    /// Ligne du montant d'un joueur : son nom, la mention du crédit invité
    /// s'il en consomme un, et ce qu'il coûte.
    ///
    /// - Parameter participant: joueur du brouillon.
    /// - Returns: la ligne, montant aligné à droite (en vert quand il ne coûte
    ///   rien).
    private func amountRow(_ participant: BookingParticipant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(participant.displayName)
                    .font(.footnote)
                    .foregroundStyle(Brand.textPrimary)

                // Un invité sur crédit : on rappelle d'où vient la gratuité.
                if participant.usesCredit {
                    Text("Crédit invité utilisé (\(participant.displayName))")
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Spacer(minLength: 0)

            Text(amountLabel(participant))
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(participant.supplement > 0 ? Brand.textPrimary : Brand.success)
                .fixedSize()
        }
    }

    /// Ce que coûte un joueur, en clair.
    ///
    /// - Parameter participant: joueur du brouillon.
    /// - Returns: le supplément en euros pour un invité au supplément,
    ///   « Gratuit » pour un invité sur crédit, « Inclus » pour un membre
    ///   (couvert par sa cotisation).
    private func amountLabel(_ participant: BookingParticipant) -> String {
        if participant.supplement > 0 { return Price.amount(participant.supplement) }
        if participant.usesCredit { return "Gratuit" }
        return "Inclus"
    }

    // MARK: - Paiement

    /// Choix du mode de paiement, affiché seulement quand un montant est dû :
    /// carte, lien envoyé à l'invité, ou sur place. Aucun ne déclenche de
    /// paiement réel (voir l'en-tête).
    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paiement")
                .metaLabelStyle()

            ForEach(PaymentMode.allCases) { mode in
                paymentOption(mode)
            }
        }
    }

    /// Une option de paiement, sous forme de bouton radio : un appui la
    /// choisit dans le brouillon.
    ///
    /// - Parameter mode: mode proposé.
    /// - Returns: la ligne, cochée si c'est le mode du brouillon (et annoncée
    ///   comme sélectionnée à VoiceOver).
    private func paymentOption(_ mode: PaymentMode) -> some View {
        let isSelected = draft.paymentMode == mode

        return Button {
            draft.paymentMode = mode
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.navy700)
                    .frame(width: 26)

                Text(mode.displayName)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Brand.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                // Pastille radio : pleine pour le mode choisi.
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? Brand.navy700 : Brand.hairline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: Radius.inner)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Conditions

    /// Interrupteur d'acceptation des conditions d'annulation du club, coché
    /// au départ (`BookingDraft.start`). Décoché, il désactive le bouton
    /// final ; l'acceptation n'est pas enregistrée en base.
    private var termsToggle: some View {
        // Copie liable du brouillon observé, pour lier l'interrupteur à sa
        // propriété `acceptsTerms`.
        @Bindable var draft = draft

        return Toggle(isOn: $draft.acceptsTerms) {
            Text("J'accepte les conditions d'annulation du club.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
        }
        .toggleStyle(.switch)
        .tint(Brand.navy700)
        .padding(14)
        .surfaceCard(cornerRadius: Radius.inner)
    }

    // MARK: - Confirmation

    /// Barre du bas : le bouton final, « Payer ... » quand un montant est dû,
    /// sinon « Confirmer la réservation ». Inactif tant que le brouillon n'est
    /// pas confirmable ou pendant l'envoi.
    private var confirmBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: draft.confirmTitle,
                systemImage: draft.requiresPayment ? "creditcard" : "checkmark",
                isLoading: isConfirming
            ) {
                // Avec un risque de pluie connu, on passe d'abord par la
                // fenêtre de confirmation ; sinon l'envoi part tout de suite
                // (y compris quand la réponse n'est pas encore arrivée, voir
                // l'en-tête).
                if rainRisk != nil {
                    asksRainConfirmation = true
                } else {
                    confirm()
                }
            }
            .disabled(!draft.canConfirm || isConfirming)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// Envoie la réservation, puis ouvre l'écran de succès.
    ///
    /// Étapes : contrôle des terrains fermés quand on agit pour un enfant ;
    /// insertion de la réservation et de ses joueurs
    /// (`ReservationService.confirm`) ; reprogrammation des rappels ;
    /// remplacement de la pile du tunnel par l'écran de succès.
    ///
    /// Erreurs : un créneau pris entre-temps ouvre la fenêtre « Créneau
    /// indisponible » ; toute autre erreur s'affiche sous le formulaire, et un
    /// refus de la base (terrain fermé au groupe, par exemple) fait relire les
    /// terrains fermés pour que le planning se mette à jour.
    ///
    /// Sans session ou sans terrain dans le brouillon, ne fait rien.
    private func confirm() {
        // Le compte connecté est l'auteur de la réservation (`created_by`),
        // même quand on réserve pour un enfant ; l'enfant est le premier des
        // joueurs du brouillon.
        guard let profile = auth.sessionProfile, let court = draft.court else { return }
        isConfirming = true
        errorMessage = nil

        Task {
            // Réservation au nom d'un enfant : on vérifie ses terrains à lui
            // avant d'envoyer quoi que ce soit.
            // (La base contrôle les groupes de l'auteur, le parent : l'app
            // n'envoie pas l'enfant comme bénéficiaire de la réservation.)
            // Attention : ce message tutoie (« contacte le club »), alors que
            // le refus rédigé par la base vouvoie (« contactez le club »).
            if auth.isActingForChild, let child = auth.activeProfile {
                let closed = await PlanningService.forbiddenCourts(clubId: profile.clubId, for: child.id)
                if closed.contains(court.id) {
                    errorMessage = "\(child.prenom ?? child.displayName) ne peut pas réserver ce terrain. Pour en savoir plus, contacte le club."
                    Haptics.warning()
                    isConfirming = false
                    return
                }
            }

            do {
                // Écriture en base : la réservation, puis ses joueurs. Le
                // mode de paiement n'est envoyé que si un montant est dû. Le
                // marqueur de pluie n'est jamais envoyé : la base le pose.
                let reservationId = try await ReservationService.confirm(
                    clubId: profile.clubId,
                    court: court,
                    date: draft.date,
                    slot: draft.slot,
                    format: draft.format,
                    participants: draft.participants,
                    total: draft.total,
                    paymentMode: draft.requiresPayment ? draft.paymentMode : nil,
                    createdBy: profile.id
                )

                Haptics.success()
                isConfirming = false
                // Rappels locaux reprogrammés dans une tâche à part, non
                // attendue : l'écran de succès s'ouvre sans attendre leur
                // lecture.
                Task { await BookingReminders.refresh(for: profile) }

                // Le tunnel se referme derrière l'écran de succès : le geste
                // arrière ne doit pas ramener sur un récapitulatif dont la
                // réservation est déjà enregistrée.
                var path = NavigationPath()
                path.append(
                    BookingConfirmation(
                        reservationId: reservationId,
                        courtName: court.nom,
                        clubName: profile.clubName,
                        date: draft.date,
                        slot: draft.slot,
                        playerCount: draft.participants.count,
                        isPaid: draft.requiresPayment,
                        participantNames: draft.participants.map(\.displayName)
                    )
                )
                router.bookingPath = path

            } catch ReservationError.slotAlreadyTaken {
                // Contrainte d'unicité : quelqu'un vient de prendre le créneau.
                isConfirming = false
                Haptics.failure()
                slotWasTaken = true
            } catch {
                isConfirming = false
                Haptics.failure()
                errorMessage = error.localizedDescription
                // Terrain fermé entre-temps : on relit les fermetures, il
                // disparaîtra du planning.
                if case ReservationError.refused = error {
                    await catalog.refreshAccess(childId: auth.isActingForChild ? auth.activeProfile?.id : nil)
                }
            }
        }
    }
}
