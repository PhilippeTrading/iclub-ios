//
//  OpenGameCard.swift
//  iClub
//
//  Une partie ouverte dans la liste de l'onglet « Parties ».
//
//  En **double**, deux colonnes ÉQUIPE A et ÉQUIPE B, deux places chacune.
//  En **simple**, une seule rangée de deux places, sans notion d'équipe.
//
//  Repliée, la carte se limite à l'essentiel (terrain, niveau, heure et une
//  pastille par place : photo du joueur, ou « + » si elle est libre) pour que
//  la journée se parcoure d'un coup d'œil. Un tap la déplie en version
//  complète, avec les badges, les équipes et le bouton d'action.
//
//  Place dans l'application
//    Construite par `OpenGamesView` (`card(for:isExpanded:onToggleExpanded:)`) :
//    repliée au départ dans la liste des parties, où chaque carte se déplie et
//    se replie au toucher ; dépliée, sans possibilité de la replier, dans le
//    détail d'une partie ouvert depuis une notification (`OpenGameDetailRoute`).
//    La carte ne lit ni n'écrit rien. La partie vient d'`OpenGamesStore`
//    (`OpenGameService.loadAll` : lignes de `reservations` avec
//    `est_partie_ouverte = true` et leurs `reservation_participants`) ; les
//    photos, prénoms, âges et classements viennent de la fonction SQL
//    `get_club_roster_info`, chargée par le même magasin. Chaque geste remonte
//    à la liste par une fermeture : fiche d'un joueur (`PlayerProfileSheet`),
//    adhésion (contrôles d'`OpenGameEligibility`, puis `join_open_game`),
//    sortie ou annulation (fenêtre de confirmation, puis `leave_open_game`).
//
//  Règles métier
//    - Le rôle de la personne (hôte, joueur inscrit, extérieur) se déduit de
//      l'identifiant du profil actif, le sien ou celui de l'enfant au nom de
//      qui l'on agit. Il décide seul du bouton d'action : « Rejoindre »,
//      « Quitter la partie » ou « Annuler la partie ».
//    - Annulation automatique : une tâche planifiée de la base annule une
//      partie dont l'hôte est encore seul 30 minutes avant le début. Dans ces
//      30 dernières minutes, la carte repliée passe l'heure en rouge, et la
//      carte dépliée ajoute un badge et un avertissement : c'est la dernière
//      chance de la rejoindre.
//    - Sous réserve de pluie : une partie posée sur un terrain couvert pendant
//      qu'un cours ou un stage du même sport se tient en extérieur porte le
//      marqueur `reservations.sous_reserve_pluie`. S'il pleut, le club passe
//      le cours en salle et la partie est annulée ; les joueurs sont prévenus
//      par courriel et par un message du club dans l'app. Repliée, la carte le
//      signale par un parapluie ; dépliée, par un badge et une note dont le
//      texte est mot pour mot celui du web (bulle du badge dans
//      `src/components/member/OpenGamesView.tsx`). Le libellé VoiceOver de la
//      carte repliée le dit aussi. Le marqueur est posé par la base à la
//      création de la réservation (déclencheur `sous_reserve_pluie`) et n'est
//      jamais recalculé ensuite (limite consignée côté web) : l'app ne fait
//      que le lire.
//
//  Points d'attention
//    - Limite connue : le web affiche aussi un badge « Adultes uniquement »
//      (`reservations.adultes_uniquement`), que l'app ne lit pas. Un mineur,
//      ou un parent qui agit pour son enfant, ne découvre cette restriction
//      qu'au refus de la base, en rejoignant.
//    - Limite connue : les places libres restent touchables pour l'hôte et
//      pour un joueur déjà inscrit. La liste lance alors l'adhésion (au padel,
//      après le choix du côté) ; la base la refuse avec son message (« Ce
//      joueur participe déjà à cette partie »), si les contrôles de l'app ne
//      l'ont pas déjà fait.
//    - Le bouton « Rejoindre » garde un texte blanc sur l'accent du sport, en
//      mode sombre aussi (fiche D13 du web) ; au pickleball, le contraste est
//      faible.
//
//  Fil d'exécution
//    Vue SwiftUI, sur l'acteur principal (isolement par défaut du projet).
//

import SwiftUI

/// Carte d'une partie ouverte : résumé compact ou version complète.
///
/// Elle ne fait aucun appel réseau : la partie et les fiches des joueurs lui
/// sont données, et chaque action est confiée à l'écran parent.
struct OpenGameCard: View {
    /// Partie affichée, telle que lue par `OpenGamesStore` (terrain, créneau,
    /// réglages, joueurs, marqueur de pluie).
    let game: OpenGame
    /// Photos, prénoms, âges et classements des joueurs, indexés par profil
    /// (`get_club_roster_info`). Un joueur absent de ce dictionnaire garde ses
    /// initiales et le premier mot de son nom affiché.
    let roster: [UUID: RosterInfoRow]
    /// Profil actif : le compte connecté, ou l'enfant au nom de qui il agit
    /// (`auth.activeProfile` dans la liste) ; `nil` sans personne connectée,
    /// qui vaut « extérieur ». La carte en déduit seule s'il est hôte, joueur
    /// ou extérieur, plutôt que de recevoir plusieurs booléens qui pourraient
    /// se contredire.
    let myProfileId: UUID?
    /// Vignette d'un joueur touchée : la liste ouvre sa fiche.
    let onSelectPlayer: (OpenGame.Player) -> Void
    /// Place libre touchée, avec l'équipe visée (`nil` en simple) : la liste
    /// lance l'adhésion dans cette équipe.
    let onSelectFreeSlot: (Team?) -> Void
    /// Bouton « Rejoindre » : la liste lance l'adhésion dans la première
    /// équipe qui a de la place (`OpenGame.firstTeamWithRoom`, `nil` en simple).
    let onJoin: () -> Void
    /// Sortie de la partie : annulation pour l'hôte, simple départ sinon. La
    /// liste demande d'abord confirmation.
    let onLeave: () -> Void
    /// Version complète (`true`, valeur par défaut), ou résumé compact.
    var isExpanded = true
    /// Bascule entre les deux versions, fournie par la liste.
    /// `nil` : la carte ne se replie pas (écran ouvert depuis une notification).
    var onToggleExpanded: (() -> Void)?

    /// Place du profil actif dans la partie : hôte, joueur inscrit ou
    /// extérieur. Elle choisit le libellé, l'icône et la couleur du bouton
    /// d'action, et le texte de l'avertissement d'annulation automatique.
    private var role: OpenGame.Role { game.role(for: myProfileId) }

    /// La version complète ou le résumé, selon `isExpanded`.
    var body: some View {
        if isExpanded {
            expandedBody
        } else {
            collapsedBody
        }
    }

    // MARK: - Repliée

    /// Résumé de la partie : terrain, niveau et format, heure, une pastille
    /// par place. Toute la carte est un seul bouton qui la déplie, lu par
    /// VoiceOver comme une seule phrase (`collapsedAccessibilityLabel`).
    private var collapsedBody: some View {
        Button { onToggleExpanded?() } label: {
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    // Première ligne : terrain, parapluie éventuel, flèche.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(game.courtName)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                            .lineLimit(1)

                        // Repliée, la carte n'a pas de badges : le parapluie
                        // suffit à signaler la partie sous réserve de pluie
                        // (marqueur `reservations.sous_reserve_pluie`, posé par
                        // la base). Le badge et la note sont dans la version
                        // dépliée.
                        if game.isRainReserve {
                            Image(systemName: "umbrella.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.navy700)
                        }

                        Spacer(minLength: 4)

                        // Flèche vers le bas : la carte se déplie au toucher.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Brand.textSecondary)
                    }

                    // Deuxième ligne : fourchette de niveau et format, par
                    // exemple « Tous niveaux · Simple ».
                    Text(game.levelAndFormatLabel)
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)

                    // Troisième ligne : l'heure du créneau, puis les pastilles
                    // des places.
                    HStack(spacing: 10) {
                        // Heure en rouge quand l'annulation automatique
                        // approche ; jamais tronquée (`fixedSize`).
                        Label(game.slot.label, systemImage: "clock")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(game.isFacingAutomaticCancellation ? Brand.error : Brand.textPrimary)
                            .lineLimit(1)
                            .fixedSize()

                        Spacer(minLength: 4)

                        seatStrip
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // Un seul élément pour VoiceOver : les textes et les pastilles sont
        // remplacés par une phrase qui résume la partie.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collapsedAccessibilityLabel)
        .accessibilityHint("Afficher le détail de la partie")
    }

    /// Une pastille par place : les places libres d'abord, comme une main
    /// tendue, puis les joueurs inscrits (équipe A puis équipe B en double).
    /// Les « + » ne sont pas des boutons : toute la carte repliée en est un,
    /// qui la déplie.
    private var seatStrip: some View {
        HStack(spacing: 6) {
            // Places libres : un « + » dans un cercle en pointillés, à la
            // couleur du sport.
            ForEach(0..<game.freeSlots, id: \.self) { _ in
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(game.sport.accent)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle().strokeBorder(
                            game.sport.accent.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
            }

            // Joueurs inscrits : la photo de leur fiche, à défaut leurs
            // initiales (celles de la fiche, sinon celles du nom affiché dans
            // la partie).
            ForEach(orderedPlayers, id: \.profileId) { player in
                let info = roster[player.profileId]
                MemberAvatar(
                    url: info?.avatarUrl.flatMap(URL.init(string:)),
                    initials: info?.initials ?? player.initials,
                    size: 34
                )
            }
        }
    }

    /// Joueurs dans l'ordre d'affichage : en simple, l'ordre où la base rend
    /// les participants (aucun tri n'est demandé) ; en double, l'équipe A puis
    /// l'équipe B.
    ///
    /// Limite connue : en double, un participant sans équipe lisible
    /// (`reservation_participants.equipe` vide ou inconnue) n'apparaît ni ici
    /// ni dans la grille des équipes, alors qu'il compte parmi les places
    /// occupées. L'app et la base donnent toujours une équipe en double
    /// (`OpenGameService.create`, `join_open_game`).
    private var orderedPlayers: [OpenGame.Player] {
        guard game.usesTeams else { return game.players }
        return Team.allCases.flatMap { game.players(in: $0) }
    }

    /// Phrase lue par VoiceOver sur la carte repliée : terrain, niveau et
    /// format, créneau, places restantes, « sous réserve de pluie » le cas
    /// échéant, puis les prénoms des joueurs (« avec A, B et C »).
    private var collapsedAccessibilityLabel: String {
        // Prénom de la fiche du joueur, à défaut le premier mot de son nom.
        let names = orderedPlayers.map { roster[$0.profileId]?.firstName ?? $0.firstName }
        var parts = [game.courtName, game.levelAndFormatLabel, game.slot.label, game.freeSlotsLabel]
        // Le parapluie de la carte repliée, dit en toutes lettres.
        if game.isRainReserve { parts.append("sous réserve de pluie") }
        // Énumération à la française : virgules, puis « et » avant le dernier.
        if !names.isEmpty { parts.append("avec " + names.formatted(.list(type: .and).locale(AppLocale.french))) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Dépliée

    /// Version complète, de haut en bas : en-tête, badges, date et heure,
    /// places (équipes en double, rangée unique en simple), avertissement
    /// d'annulation automatique, note de pluie, bouton d'action.
    private var expandedBody: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                header
                badges
                schedule

                // Deux colonnes d'équipes en double, une seule rangée en simple.
                if game.usesTeams {
                    teamColumns
                } else {
                    singlesRow
                }

                // Dans les 30 dernières minutes, si l'hôte est encore seul.
                if game.isFacingAutomaticCancellation {
                    cancellationWarning
                }

                // Sous réserve de pluie : la note qui explique le badge.
                if game.isRainReserve {
                    rainReserveNote
                }

                actionButton
            }
        }
    }

    // MARK: - En-tête

    /// Toute la bande du haut replie la carte, pas seulement la flèche : c'est
    /// là que le doigt revient naturellement après l'avoir dépliée.
    ///
    /// Sans `onToggleExpanded` (détail ouvert depuis une notification), la
    /// bande est un simple affichage.
    @ViewBuilder
    private var header: some View {
        if let onToggleExpanded {
            Button { onToggleExpanded() } label: {
                headerContent
                    // Toute la surface de la bande répond au toucher, blancs
                    // compris.
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Replier la partie")
        } else {
            headerContent
        }
    }

    /// Contenu de la bande du haut : icône du sport, terrain, niveau et
    /// format, places restantes, et la flèche de repli quand elle sert.
    private var headerContent: some View {
        HStack(spacing: 12) {
            // Icône du sport dans un disque teinté de sa couleur.
            Image(systemName: game.sport.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(game.sport.accent)
                .frame(width: 38, height: 38)
                .background(game.sport.accent.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.courtName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)

                // Deux lignes : avec la pastille et la flèche, une seule
                // tronquait le format (« Dou… »).
                Text(game.levelAndFormatLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // « 2 places », « 1 place » ou « Complet » ; grisé quand la partie
            // est complète, à la couleur du sport sinon.
            BrandChip(
                title: game.freeSlotsLabel,
                tint: game.isFull ? Brand.textSecondary : game.sport.accent
            )
            .fixedSize()

            // Flèche vers le haut, seulement si la carte peut se replier ;
            // VoiceOver l'ignore, la consigne « Replier la partie » suffit.
            if onToggleExpanded != nil {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Badges

    /// Rangée de badges de la partie, absente quand elle n'en a aucun (voir
    /// `badgeItems`).
    @ViewBuilder
    private var badges: some View {
        let items = badgeItems

        if !items.isEmpty {
            // Une partie loisir et mixte n'a aucun badge : c'est le cas
            // courant, et la carte reste dégagée.
            HStack(spacing: 6) {
                // Les titres sont tous différents : ils servent d'identifiant.
                ForEach(items, id: \.title) { item in
                    BrandChip(title: item.title, systemImage: item.symbol, tint: item.tint)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Badges de la partie, dans l'ordre d'affichage :
    /// - « Compétitif » (flamme, couleur terre battue) pour une ambiance
    ///   compétitive ;
    /// - « Hommes uniquement » ou « Femmes uniquement » (bleu marine) pour une
    ///   partie non mixte ;
    /// - « Annulation imminente » (rouge) dans les 30 dernières minutes, si
    ///   l'hôte est encore seul ;
    /// - « Sous réserve de pluie » (parapluie, bleu marine) quand la base a
    ///   posé le marqueur, comme le badge du web.
    ///
    /// - Returns: titre, symbole SF et teinte de chaque badge ; vide pour une
    ///   partie loisir, mixte, sans urgence ni réserve de pluie.
    private var badgeItems: [(title: String, symbol: String?, tint: Color)] {
        var items: [(String, String?, Color)] = []

        // Ambiance : seule « Compétitif » porte un badge.
        if let badge = game.ambiance.badge {
            items.append((badge, "flame", Brand.clay800))
        }
        // Mixité : rien pour une partie mixte.
        if let badge = game.mixite.badge {
            items.append((badge, "person.2", Brand.navy700))
        }
        // Annulation automatique proche (hôte seul, moins de 30 minutes).
        if game.isFacingAutomaticCancellation {
            items.append(("Annulation imminente", "exclamationmark.triangle.fill", Brand.error))
        }
        // Marqueur de pluie posé par la base à la création de la réservation.
        if game.isRainReserve {
            items.append(("Sous réserve de pluie", "umbrella.fill", Brand.navy700))
        }

        // Étiquettes nommées, pour la lecture dans `badges`.
        return items.map { (title: $0.0, symbol: $0.1, tint: $0.2) }
    }

    /// Sous-titre du badge « Sous réserve de pluie », mot pour mot le web, où
    /// il sert de bulle au survol du badge
    /// (`src/components/member/OpenGamesView.tsx`). Ici, la phrase s'affiche
    /// en toutes lettres sous les places de la carte dépliée.
    private var rainReserveNote: some View {
        Label {
            Text("S'il pleut, le cours qui se tient en extérieur à cette heure-là passe en salle et la partie est annulée. Les joueurs sont prévenus par courriel et dans l'application.")
        } icon: {
            Image(systemName: "umbrella.fill")
                .foregroundStyle(Brand.navy700)
        }
        .font(.caption)
        .foregroundStyle(Brand.textSecondary)
        // Le texte passe à la ligne autant qu'il faut, sans être tronqué.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Créneau

    /// Date en toutes lettres (« Samedi 31 octobre 2026 ») et heures de début
    /// et de fin du créneau, sur une ligne, réduite jusqu'à 85 % plutôt que
    /// tronquée.
    private var schedule: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.textSecondary)

            Text("\(game.date.longFrenchDate) · \(game.slot.label)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Joueurs

    /// Places d'une partie en double : une colonne par équipe, son nom en
    /// tête, puis deux places.
    ///
    /// `Grid` et non deux `VStack` côte à côte : une grille impose une hauteur
    /// commune à toutes les cellules d'une même rangée. Avec deux colonnes
    /// indépendantes, une vignette de joueur (plus haute qu'un « + » vide)
    /// décalait toute la colonne d'en face.
    private var teamColumns: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            // Rangée de titres : « Équipe A », « Équipe B ».
            GridRow {
                ForEach(Team.allCases) { team in
                    Text(team.displayName)
                        .metaLabelStyle()
                        .frame(maxWidth: .infinity)
                }
            }

            // Deux rangées : la première place de chaque équipe, puis la
            // seconde.
            ForEach(0..<2, id: \.self) { index in
                GridRow {
                    ForEach(Team.allCases) { team in
                        slot(for: team, at: index)
                    }
                }
            }
        }
    }

    /// Places d'une partie en simple : le titre « Joueurs », puis deux places
    /// côte à côte, sans équipe.
    private var singlesRow: some View {
        VStack(spacing: 6) {
            Text("Joueurs")
                .metaLabelStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Même raison qu'en double : les deux places doivent faire la même
            // hauteur, qu'elles soient occupées ou libres.
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<2, id: \.self) { index in
                        slot(for: nil, at: index)
                    }
                }
            }
        }
    }

    /// Une place de la grille : la vignette du joueur qui l'occupe, ou un
    /// « + » libre.
    ///
    /// - Parameters:
    ///   - team: équipe de la place ; `nil` en simple, où toutes les places
    ///     se partagent la liste des joueurs.
    ///   - index: rang de la place dans son équipe (0 ou 1).
    /// - Returns: `PlayerSlotView`, dont le toucher ouvre la fiche du joueur ;
    ///   sinon `EmptySlotView`, dont le toucher lance l'adhésion dans cette
    ///   équipe. Voir l'en-tête : une place libre reste touchable pour qui est
    ///   déjà dans la partie.
    @ViewBuilder
    private func slot(for team: Team?, at index: Int) -> some View {
        // Joueurs de l'équipe en double, tous les joueurs en simple.
        let occupants = team.map { game.players(in: $0) } ?? game.players

        if index < occupants.count {
            let player = occupants[index]
            PlayerSlotView(
                player: player,
                info: roster[player.profileId],
                sport: game.sport,
                // Le côté (gauche, droite) ne s'affiche qu'au padel.
                showsSide: game.usesSides,
                onTap: { onSelectPlayer(player) }
            )
        } else {
            EmptySlotView(sport: game.sport) { onSelectFreeSlot(team) }
        }
    }

    // MARK: - Annulation imminente

    /// Avertissement rouge des 30 dernières minutes quand l'hôte est encore
    /// seul. Le texte s'adresse à l'hôte (« Personne ne vous a rejoint... »)
    /// ou aux autres (« Sans joueur supplémentaire... »), selon le rôle.
    private var cancellationWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
            Text(game.automaticCancellationWarning(isHost: role == .host))
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Brand.error)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Fond rouge très léger (8 %), aux coins continus des pastilles.
        .background(Brand.error.opacity(0.08), in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }

    // MARK: - Action

    /// Un seul bouton, trois libellés selon la place de l'utilisateur :
    /// « Rejoindre » pour un extérieur, « Quitter la partie » pour un joueur
    /// inscrit, « Annuler la partie » pour l'hôte.
    ///
    /// Les deux sorties passent en teinte d'alerte : ce ne sont pas des actions
    /// qu'on déclenche par mégarde, et l'annulation touche tous les joueurs.
    ///
    /// Le bouton n'est jamais désactivé ici. Une partie complète, commencée ou
    /// annulée n'apparaît pas dans la liste ; dans le détail ouvert depuis une
    /// notification, la liste l'annonce par un bandeau au-dessus de la carte,
    /// et la base refuse l'adhésion avec son message.
    private var actionButton: some View {
        // Hôte ou joueur inscrit : le bouton fait sortir de la partie.
        let isLeaving = role != .outsider

        return Button {
            isLeaving ? onLeave() : onJoin()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: OpenGame.actionSymbol(for: role))
                    .font(.system(size: 13, weight: .semibold))
                Text(OpenGame.actionTitle(for: role))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            // Sortie : texte rouge sur fond rouge pâle, liseré rouge.
            // Rejoindre : texte blanc sur la couleur du sport.
            .foregroundStyle(isLeaving ? Brand.error : Color.white)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isLeaving ? Brand.error.opacity(0.10) : game.sport.accent)
            }
            .overlay {
                // Liseré, seulement pour les sorties.
                if isLeaving {
                    RoundedRectangle.squircle(Radius.chip)
                        .strokeBorder(Brand.error.opacity(0.30), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Aperçu

/// Aperçu Xcode, données fictives et aucun appel réseau : deux cartes
/// repliées, puis trois dépliées vues par l'hôte, par un joueur inscrit et
/// par un extérieur.
#Preview {
    // Fiche de joueur fabriquée à partir d'un JSON : `RosterInfoRow` ne se
    // construit qu'en décodant, comme la réponse de `get_club_roster_info`.
    func roster(_ id: UUID, _ prenom: String, _ age: Int, _ padel: String) -> RosterInfoRow {
        var json = "{\"profile_id\":\"" + id.uuidString + "\""
        json += ",\"prenom\":\"" + prenom + "\",\"nom\":\"Test\",\"avatar_url\":null"
        json += ",\"age\":" + String(age)
        json += ",\"classement_tennis\":\"30/1\",\"classement_padel\":" + padel + "}"
        return try! JSONDecoder().decode(RosterInfoRow.self, from: Data(json.utf8))
    }

    // Deux joueurs fictifs, un dans chaque équipe, avec leur côté au padel.
    let marieId = UUID(), camilleId = UUID()
    let marie = OpenGame.Player(profileId: marieId, displayName: "Marie Dupont", team: .a, side: .gauche)
    let camille = OpenGame.Player(profileId: camilleId, displayName: "Camille Roux", team: .b, side: .droite)

    // Leurs fiches : âge et classement padel.
    let infos = [
        marieId: roster(marieId, "Marie", 20, "4.5"),
        camilleId: roster(camilleId, "Camille", 34, "4.0"),
    ]

    // Cas signalé : un seul joueur en équipe A. Sa vignette est plus haute
    // qu'un « + » vide, et c'est là que le décalage se voyait.
    let hostAlone = OpenGame(
        id: UUID(), date: Date.now.addingTimeInterval(86400 * 3),
        slot: TimeSlot(startMinutes: 13 * 60 + 30, durationMinutes: 90),
        sport: .padel, courtName: "Padel 1", format: .double, mixite: .mixte,
        ambiance: .competitif, niveauMin: nil, niveauMax: nil,
        hostId: marieId, isCancelled: false, players: [marie]
    )

    // Double féminin et compétitif, avec une fourchette de niveau : deux
    // badges, deux places libres.
    let padelDouble = OpenGame(
        id: UUID(), date: Date.now.addingTimeInterval(86400 * 2),
        slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 90),
        sport: .padel, courtName: "Padel 1", format: .double, mixite: .femmes,
        ambiance: .competitif, niveauMin: "4.0", niveauMax: "5.0",
        hostId: marieId, isCancelled: false, players: [marie, camille]
    )

    // Simple de tennis qui commence dans dix minutes avec l'hôte seul :
    // l'annulation automatique est imminente.
    let tennisSingles = OpenGame(
        id: UUID(), date: Date.now.addingTimeInterval(600),
        slot: TimeSlot(
            startMinutes: Calendar.current.component(.hour, from: .now) * 60
                + Calendar.current.component(.minute, from: .now) + 10,
            durationMinutes: 60
        ),
        sport: .tennis, courtName: "Central", format: .simple, mixite: .mixte,
        ambiance: .loisir, niveauMin: nil, niveauMax: nil,
        hostId: marieId, isCancelled: false,
        players: [OpenGame.Player(profileId: marieId, displayName: "Marie Dupont", team: nil, side: .indifferent)]
    )

    // Les trois rôles, dans l'ordre : hôte, joueur inscrit, extérieur.
    let outsiderId = UUID()

    return ScrollView {
        VStack(spacing: 12) {
            // Repliées, telles qu'affichées dans la liste.
            OpenGameCard(game: padelDouble, roster: infos, myProfileId: outsiderId,
                         onSelectPlayer: { _ in }, onSelectFreeSlot: { _ in },
                         onJoin: {}, onLeave: {}, isExpanded: false, onToggleExpanded: {})
            OpenGameCard(game: tennisSingles, roster: infos, myProfileId: outsiderId,
                         onSelectPlayer: { _ in }, onSelectFreeSlot: { _ in },
                         onJoin: {}, onLeave: {}, isExpanded: false, onToggleExpanded: {})
            // Dépliées, sans repli : l'hôte seul, un joueur inscrit, un
            // extérieur.
            OpenGameCard(game: hostAlone, roster: infos, myProfileId: marieId,
                         onSelectPlayer: { _ in }, onSelectFreeSlot: { _ in },
                         onJoin: {}, onLeave: {})
            OpenGameCard(game: padelDouble, roster: infos, myProfileId: camilleId,
                         onSelectPlayer: { _ in }, onSelectFreeSlot: { _ in },
                         onJoin: {}, onLeave: {})
            OpenGameCard(game: tennisSingles, roster: infos, myProfileId: outsiderId,
                         onSelectPlayer: { _ in }, onSelectFreeSlot: { _ in },
                         onJoin: {}, onLeave: {})
        }
        .padding(20)
    }
    .background(Brand.background)
}
