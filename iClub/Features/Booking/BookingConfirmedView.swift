//
//  BookingConfirmedView.swift
//  iClub
//
//  Écran de succès, et non un simple retour en arrière : la confirmation est
//  un aboutissement, elle mérite son écran.
//
//  La route porte toutes ses données : elle reste affichable même si le
//  brouillon du tunnel est réinitialisé derrière elle.
//
//  Le même écran sert, depuis le travail du 30 octobre 2026, après avoir
//  rejoint une partie ouverte : l'appelant fournit alors son titre, le
//  libellé et le symbole du bouton du bas, et l'action de ce bouton.
//
//  Place dans l'application
//    - Tunnel de réservation : destination `BookingConfirmation` déclarée
//      dans `BookingView`. `BookingSummaryView` remplace toute la pile du
//      tunnel par cet écran une fois la réservation enregistrée ; le bouton
//      du bas referme le tunnel et ouvre l'accueil.
//    - Parties ouvertes : destination `OpenGameJoinedConfirmation`
//      (`OpenGameConfirmedView.swift`) déclarée dans `OpenGamesView`, qui
//      l'affiche avec son propre titre (« Vous avez rejoint la partie ») et
//      le bouton « Voir les parties ouvertes », qui ramène à la liste.
//
//  Contenu
//    Coche animée et titre ; carte du jour, de l'état (« Payé » ou
//    « Confirmée »), du créneau, du terrain, du club et du nombre de
//    joueurs ; ajout au calendrier de l'appareil ; partage d'un résumé ;
//    bouton de retour.
//
//  Effets de bord
//    Rien n'est écrit en base. Création d'un événement dans le calendrier de
//    l'appareil (`CalendarExport`, accès en écriture seule demandé au premier
//    ajout), feuille de partage du système, proposition d'activer les
//    notifications (`offersNotificationOptIn` : écran d'explication présenté
//    tant qu'iOS n'a jamais posé la question, et pas dans les 7 jours qui
//    suivent un refus), navigation.
//
//  Points d'attention
//    - Attention : l'état « Payé » s'affiche dès qu'un montant était dû
//      (`isPaid` reçoit `BookingDraft.requiresPayment`), alors que l'app
//      n'encaisse rien : les modes de paiement sont des intentions. Une
//      réservation avec un montant dû est d'ailleurs refusée par la base
//      aujourd'hui (voir `BookingSummaryView`), si bien que le cas ne se
//      présente pas.
//    - Heures de l'événement de calendrier calculées dans le fuseau de
//      l'appareil, pas dans celui du club. L'événement n'est ni mis à jour
//      ni supprimé si la réservation est annulée ensuite.
//    - Textes du code laissés tels quels : le titre de l'événement sépare le
//      terrain et le club par un tiret cadratin ; le résumé partagé dit
//      « Réservation confirmée ! » même après avoir rejoint une partie ; le
//      message d'ajout au calendrier tutoie, quand le titre de l'écran
//      vouvoie.
//
//  Fil d'exécution
//    Vue SwiftUI, sur l'acteur principal ; l'ajout au calendrier est lancé
//    dans une tâche asynchrone.
//

import SwiftUI

/// Destination de l'écran de succès. `Hashable` et autoportante.
struct BookingConfirmation: Hashable {
    /// Réservation enregistrée (`reservations.id`) ; pour une partie
    /// rejointe, la partie elle-même, qui est une réservation.
    let reservationId: UUID
    /// Nom du terrain (`courts.nom`).
    let courtName: String
    /// Nom du club, affiché et repris dans le titre de l'événement ; chaîne
    /// vide si la session ne le connaît pas.
    let clubName: String
    /// Jour du créneau (minuit, fuseau de l'appareil).
    let date: Date
    /// Créneau : début et durée, en minutes depuis minuit.
    let slot: TimeSlot
    /// Nombre de joueurs annoncé sur la carte.
    let playerCount: Int
    /// Vrai quand un montant était dû : la carte affiche alors « Payé » au
    /// lieu de « Confirmée » (voir l'en-tête).
    let isPaid: Bool
    /// Noms affichés des joueurs, repris dans le partage et dans les notes de
    /// l'événement de calendrier.
    let participantNames: [String]

    /// Début réel de l'événement de calendrier : le jour, plus l'heure de
    /// début du créneau, dans le calendrier de l'appareil. Retombe sur `date`
    /// si le calcul échoue.
    var startsAt: Date {
        let calendar = Calendar.current
        return calendar.date(
            byAdding: .minute,
            value: slot.startMinutes,
            to: calendar.startOfDay(for: date)
        ) ?? date
    }

    /// Fin réelle de l'événement : le début plus la durée du créneau.
    var endsAt: Date {
        startsAt.addingTimeInterval(TimeInterval(slot.durationMinutes * 60))
    }

    /// Titre de l'événement de calendrier : le nom du terrain, puis celui du
    /// club, séparés par un tiret cadratin entouré d'espaces.
    var eventTitle: String { "\(courtName) — \(clubName)" }

    /// Résumé partagé par la feuille de partage : confirmation, terrain et
    /// club, jour, heures et liste des joueurs, une information par ligne.
    var shareText: String {
        """
        Réservation confirmée !
        \(courtName) · \(clubName)
        \(date.longFrenchDate)
        \(slot.label)
        Joueurs : \(participantNames.joined(separator: ", "))
        """
    }
}

/// Écran de succès après une réservation de terrain, ou après avoir rejoint
/// une partie ouverte.
struct BookingConfirmedView: View {
    /// Ce qui a été réservé ou rejoint.
    let confirmation: BookingConfirmation
    // Même écran après avoir rejoint une partie ouverte : seuls le titre et
    // le bouton du bas changent.

    /// Titre affiché sous la coche.
    var title = "Votre réservation est confirmée"
    /// Libellé du bouton du bas.
    var doneTitle = "Retour à l'accueil"
    /// Symbole SF du bouton du bas.
    var doneSymbol = "house"
    /// Action du bouton du bas.
    /// `nil` : on referme le tunnel de réservation (et l'accueil s'ouvre).
    var onDone: (() -> Void)?

    /// Piles de navigation des onglets (fermeture du tunnel de réservation).
    @Environment(AppRouter.self) private var router

    /// Résultat du dernier ajout au calendrier, `nil` avant tout essai.
    @State private var calendarMessage: String?
    /// Vrai après un ajout réussi : le bouton se désactive, pour ne pas créer
    /// l'événement deux fois.
    @State private var calendarDidSucceed = false
    /// Vrai pendant l'ajout au calendrier (demande d'accès comprise).
    @State private var isAddingToCalendar = false

    /// L'écran : coche et titre, récapitulatif, actions, message du
    /// calendrier, et le bouton de retour fixé en bas.
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                successMark
                recapCard
                actions

                // Réussite ou échec de l'ajout au calendrier.
                if let calendarMessage {
                    InlineMessage(
                        kind: calendarDidSucceed ? .success : .error,
                        message: calendarMessage
                    )
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("")
        // Le tunnel est déjà refermé : on masque aussi le bouton retour pour
        // qu'aucun geste ne ramène dans un récapitulatif périmé.
        // (Après une partie rejointe, seul le bouton du bas ramène à la liste.)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) { homeBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Le membre vient de voir la valeur de l'app : c'est le moment de
        // proposer les notifications de parties.
        // (Message par défaut, celui des parties ; présenté une seconde après
        // l'affichage, si `PushService` juge le moment permis.)
        .offersNotificationOptIn(when: true)
    }

    // MARK: - Coche

    /// Coche verte animée une fois, puis le titre de l'écran.
    private var successMark: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(Brand.success)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text(title)
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Récapitulatif

    /// Carte du récapitulatif : jour et état, créneau, puis terrain, club et
    /// nombre de joueurs.
    private var recapCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                // Jour en toutes lettres et pastille d'état.
                HStack {
                    Text(confirmation.date.longFrenchDate)
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    BrandChip(
                        title: confirmation.isPaid ? "Payé" : "Confirmée",
                        systemImage: "checkmark.seal.fill",
                        tint: Brand.success
                    )
                }

                Text(confirmation.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                Divider().opacity(0.4)

                detailRow(systemImage: "sportscourt", text: confirmation.courtName)
                detailRow(systemImage: "building.2", text: confirmation.clubName)
                // « 1 joueur », « 4 joueurs ».
                detailRow(
                    systemImage: "person.2",
                    text: "\(confirmation.playerCount) joueur\(confirmation.playerCount > 1 ? "s" : "")"
                )
            }
        }
    }

    /// Une ligne du récapitulatif : un symbole, puis un texte.
    ///
    /// - Parameters:
    ///   - systemImage: symbole SF de la ligne.
    ///   - text: texte affiché.
    /// - Returns: la ligne, alignée à gauche.
    private func detailRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.textPrimary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    /// Ajout au calendrier (inactif pendant l'ajout et après une réussite) et
    /// partage du résumé aux autres joueurs.
    private var actions: some View {
        VStack(spacing: 10) {
            SecondaryActionButton(
                title: isAddingToCalendar ? "Ajout en cours…" : "Ajouter à mon calendrier",
                systemImage: "calendar.badge.plus"
            ) {
                addToCalendar()
            }
            .disabled(isAddingToCalendar || calendarDidSucceed)

            // Feuille de partage du système, avec le résumé texte.
            ShareLink(item: confirmation.shareText) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Partager aux participants")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    /// Crée l'événement dans le calendrier de l'appareil : titre terrain et
    /// club, bornes du créneau, liste des joueurs en notes. Le résultat
    /// s'affiche sous les actions ; un refus d'accès donne le message de
    /// `CalendarExportError`.
    private func addToCalendar() {
        isAddingToCalendar = true
        calendarMessage = nil

        Task {
            do {
                // Demande l'accès au premier ajout, puis enregistre
                // l'événement.
                try await CalendarExport.addEvent(
                    title: confirmation.eventTitle,
                    start: confirmation.startsAt,
                    end: confirmation.endsAt,
                    notes: "Joueurs : \(confirmation.participantNames.joined(separator: ", "))"
                )
                calendarDidSucceed = true
                calendarMessage = "Ajouté à ton calendrier."
                Haptics.success()
            } catch {
                calendarDidSucceed = false
                calendarMessage = error.localizedDescription
                Haptics.warning()
            }
            isAddingToCalendar = false
        }
    }

    // MARK: - Retour

    /// Barre du bas : le bouton de retour. Sans action fournie, il referme le
    /// tunnel de réservation et ouvre l'accueil (`closeBookingFlow`) ; après
    /// une partie rejointe, il exécute l'action de `OpenGamesView`.
    private var homeBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(title: doneTitle, systemImage: doneSymbol) {
                if let onDone { onDone() } else { router.closeBookingFlow() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}

/// Aperçu Xcode, avec des données fictives : une réservation de quatre
/// joueurs, marquée payée. Jamais affiché dans l'app.
#Preview {
    NavigationStack {
        BookingConfirmedView(
            confirmation: BookingConfirmation(
                reservationId: UUID(),
                courtName: "Central",
                clubName: "Tennis Club de la Plaine",
                date: .now,
                slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 60),
                playerCount: 4,
                isPaid: true,
                participantNames: ["Marie Dupont", "Camille Roux", "Léa Martin", "Paul Bernard"]
            )
        )
    }
    .environment(AppRouter())
}
