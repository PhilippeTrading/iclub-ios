//
//  OpenGameConfirmedView.swift
//  iClub
//
//  Écran de succès après l'ouverture d'une partie.
//
//  La route porte toutes ses données : elle reste affichable même si le
//  magasin se recharge derrière elle.
//
//  Le fichier déclare aussi, depuis le travail du 30 octobre 2026, la route de
//  l'écran de succès après avoir rejoint une partie
//  (`OpenGameJoinedConfirmation`). Cet écran-là n'est pas celui-ci : c'est
//  l'écran de succès d'une réservation (`BookingConfirmedView`), avec son
//  propre titre.
//
//  Place dans l'application
//    Onglet « Parties ». Les deux destinations sont déclarées dans
//    `OpenGamesView`. `OpenGameFormView` remplace toute la pile de l'onglet
//    par `OpenGameConfirmation` une fois la partie créée ; `OpenGamesView`
//    ajoute `OpenGameJoinedConfirmation` à la pile une fois la partie
//    rejointe. Le bouton du bas vide la pile : retour à la liste.
//
//  Effets de bord
//    Rien n'est écrit en base. Proposition d'activer les notifications
//    (`offersNotificationOptIn` : écran d'explication présenté tant qu'iOS
//    n'a jamais posé la question, et pas dans les 7 jours qui suivent un
//    refus) ; navigation.
//
//  Points d'attention
//    Textes du code laissés tels quels : le sous-titre de la coche contient
//    un tiret cadratin ; « vous êtes inscrit » est au masculin quel que soit
//    l'hôte (c'est toujours le compte connecté, jamais un enfant).
//
//  Fil d'exécution
//    Vue SwiftUI, sur l'acteur principal.
//

import SwiftUI

/// Destination de l'écran de succès après l'ouverture d'une partie.
/// `Hashable` et autoportante : tout ce qu'elle affiche est copié dedans.
struct OpenGameConfirmation: Hashable {
    /// Partie créée (`reservations.id` : une partie ouverte est une
    /// réservation).
    let gameId: UUID
    /// Nom du terrain (`courts.nom`).
    let courtName: String
    /// Sport de la partie : couleur de la pastille de format et symbole du
    /// terrain.
    let sport: Sport
    /// Jour de la partie (minuit, fuseau de l'appareil).
    let date: Date
    /// Créneau : début et durée, en minutes depuis minuit.
    let slot: TimeSlot
    /// Simple ou double : donne aussi le nombre de joueurs attendus.
    let format: GameFormat
    /// Niveau recherché, déjà rédigé par le formulaire : la fourchette de
    /// classement, ou « Tous niveaux ».
    let levelLabel: String
}

/// Écran de succès après avoir rejoint une partie : le même que pour une
/// réservation classique.
/// Route ajoutée à la pile de l'onglet « Parties » par `OpenGamesView`, qui
/// l'affiche avec `BookingConfirmedView`.
struct OpenGameJoinedConfirmation: Hashable {
    /// Ce qui s'affiche dans l'écran de réservation confirmée : terrain, club,
    /// jour, créneau, joueurs (jamais « Payé » : une partie rejointe n'a rien
    /// à régler ici).
    let booking: BookingConfirmation
    /// Prénom de l'enfant inscrit, quand on agit pour lui.
    /// (À défaut de prénom, son nom affiché ; `nil` quand on a rejoint pour
    /// soi.)
    let childName: String?

    /// Titre de l'écran : « Vous avez rejoint la partie », ou, pour un
    /// enfant, son prénom suivi de « a rejoint la partie ».
    var title: String {
        childName.map { "\($0) a rejoint la partie" } ?? "Vous avez rejoint la partie"
    }
}

/// Écran de succès après l'ouverture d'une partie : coche, titre, rappel du
/// nombre de joueurs attendus, carte du récapitulatif, bouton de retour à la
/// liste.
struct OpenGameConfirmedView: View {
    /// Ce qui vient d'être ouvert.
    let confirmation: OpenGameConfirmation

    /// Piles de navigation des onglets (ici, celle de l'onglet « Parties »).
    @Environment(AppRouter.self) private var router

    /// L'écran : coche et textes, récapitulatif, et le bouton de retour fixé
    /// en bas.
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                successMark
                recapCard
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("")
        // Le tunnel est déjà refermé : le geste arrière ne doit pas ramener sur
        // un formulaire dont la partie est déjà créée.
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) { listBar }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Le membre vient de voir la valeur de l'app : c'est le moment de
        // proposer les notifications de parties.
        .offersNotificationOptIn(when: true)
    }

    // MARK: - Coche

    /// Coche verte animée une fois, titre, puis le nombre de joueurs attendus
    /// (2 en simple, 4 en double).
    private var successMark: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(Brand.success)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text("Votre partie est ouverte")
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)
                .multilineTextAlignment(.center)

            Text("\(confirmation.format.capacity) joueurs attendus — les autres membres peuvent maintenant vous rejoindre.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Récapitulatif

    /// Carte du récapitulatif : jour et format, créneau, puis terrain, niveau
    /// et rappel que l'hôte est inscrit.
    private var recapCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                // Jour en toutes lettres et pastille du format, aux couleurs
                // du sport.
                HStack {
                    Text(confirmation.date.longFrenchDate)
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    BrandChip(
                        title: confirmation.format.displayName,
                        tint: confirmation.sport.accent
                    )
                }

                Text(confirmation.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                Divider().opacity(0.4)

                row(systemImage: confirmation.sport.symbolName, text: confirmation.courtName)
                row(systemImage: "chart.bar", text: confirmation.levelLabel)
                // L'hôte occupe déjà la première place de la partie.
                row(
                    systemImage: "person.2",
                    text: "\(confirmation.format.capacity) joueurs · vous êtes inscrit"
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
    private func row(systemImage: String, text: String) -> some View {
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

    // MARK: - Retour

    /// Barre du bas : « Voir les parties ouvertes » vide la pile de l'onglet,
    /// ce qui ramène à la liste, où la nouvelle partie apparaît.
    private var listBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(title: "Voir les parties ouvertes", systemImage: "list.bullet") {
                router.openGamesPath = NavigationPath()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
