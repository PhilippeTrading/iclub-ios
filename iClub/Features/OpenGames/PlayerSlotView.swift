//
//  PlayerSlotView.swift
//  iClub
//
//  Une place dans une partie ouverte : un joueur présent, ou un « + » libre.
//
//  Un joueur affiche, de haut en bas : photo, **prénom seul**, âge et
//  classement, et, au padel uniquement, sa position.
//
//  Le prénom seul est un choix délibéré : un nom complet se tronque dans une
//  vignette de cette largeur et devient illisible.
//
//  Place dans l'application
//    Vignettes de la grille des joueurs d'une carte de partie
//    (`OpenGameCard`, onglet « Parties »). Toucher un joueur ouvre sa fiche
//    (`PlayerProfileSheet`) ; toucher une place libre lance l'adhésion à la
//    partie, dans l'équipe de cette place (décidé par la carte et la liste).
//
//  Données
//    Aucune lecture ici : le joueur vient de la partie
//    (`reservation_participants`), sa photo, son âge et ses classements de la
//    fonction SQL `get_club_roster_info`, chargés par `OpenGamesStore`.
//

import SwiftUI

/// Vignette d'un joueur inscrit à une partie ouverte.
struct PlayerSlotView: View {
    /// Joueur inscrit (profil, nom affiché, équipe, côté).
    let player: OpenGame.Player
    /// Photo, âge et classements. `nil` tant que la fonction n'a pas répondu.
    let info: RosterInfoRow?
    /// Sport de la partie : choisit le classement affiché et la couleur.
    let sport: Sport
    /// Le côté ne s'affiche qu'au padel : ailleurs les joueurs changent de
    /// côté en permanence.
    let showsSide: Bool
    /// Action du tap : ouverture de la fiche du joueur.
    let onTap: () -> Void

    /// Vignette empilée : photo, prénom, âge et classement, côté.
    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 5) {
                // Photo, ou initiales tant qu'elle n'est pas connue.
                MemberAvatar(
                    url: info?.avatarUrl.flatMap(URL.init(string:)),
                    initials: info?.initials ?? player.initials,
                    size: 46
                )

                // Prénom de la fiche, à défaut le premier mot du nom affiché.
                Text(info?.firstName ?? player.firstName)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)

                // « 20 ans · 15/2 », si l'une des deux informations existe.
                if let detail = ageAndRanking {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

                // Position choisie au padel (gauche, droite, indifférent).
                if showsSide {
                    Text(player.side.displayName)
                        .font(.system(size: 10, design: .rounded).weight(.semibold))
                        .foregroundStyle(sport.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(sport.accent.opacity(0.12), in: .capsule)
                }
            }
            // `maxHeight` autant que `maxWidth` : la grille donne à la rangée la
            // hauteur de sa plus grande cellule, et chaque vignette doit
            // l'occuper entièrement pour que les bords s'alignent.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .surfaceCard(cornerRadius: Radius.chip)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Voir la fiche du joueur")
    }

    /// « 20 ans · 15/2 ». Le classement est celui du sport de la partie, et il
    /// n'y en a aucun en pickleball.
    /// `nil` quand ni l'âge ni le classement ne sont connus.
    private var ageAndRanking: String? {
        var parts: [String] = []
        if let age = info?.age, age > 0 { parts.append("\(age) ans") }
        if let ranking = info?.ranking(for: sport) { parts.append(ranking) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Libellé VoiceOver : prénom, âge et classement, côté au padel.
    private var accessibilityLabel: String {
        var parts = [info?.firstName ?? player.firstName]
        if let ageAndRanking { parts.append(ageAndRanking) }
        if showsSide { parts.append("côté \(player.side.displayName)") }
        return parts.joined(separator: ", ")
    }
}

/// Place libre : un bouton « + » tapable.
/// Cadre en pointillés de la couleur du sport ; le tap lance l'adhésion.
struct EmptySlotView: View {
    /// Sport de la partie, pour la couleur.
    let sport: Sport
    /// Action du tap : rejoindre la partie à cette place.
    let onTap: () -> Void

    /// « + » dans un disque teinté et la mention « Libre ».
    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(sport.accent)
                    .frame(width: 46, height: 46)
                    .background(sport.accent.opacity(0.10), in: .circle)

                Text("Libre")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            // Même hauteur que les vignettes de joueurs de la rangée.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .strokeBorder(
                        sport.accent.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Place libre, rejoindre la partie")
    }
}
