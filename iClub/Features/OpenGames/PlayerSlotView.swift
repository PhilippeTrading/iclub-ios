//
//  PlayerSlotView.swift
//  iClub
//
//  Une place dans une partie ouverte : un joueher présent, ou un « + » libre.
//
//  Un joueur affiche, de haut en bas : photo, **prénom seul**, âge et
//  classement, et — au padel uniquement — sa position.
//
//  Le prénom seul est un choix délibéré : un nom complet se tronque dans une
//  vignette de cette largeur et devient illisible.
//

import SwiftUI

struct PlayerSlotView: View {
    let player: OpenGame.Player
    /// Photo, âge et classements. `nil` tant que la fonction n'a pas répondu.
    let info: RosterInfoRow?
    let sport: Sport
    /// Le côté ne s'affiche qu'au padel : ailleurs les joueurs changent de
    /// côté en permanence.
    let showsSide: Bool
    let onTap: () -> Void

    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 5) {
                MemberAvatar(
                    url: info?.avatarUrl.flatMap(URL.init(string:)),
                    initials: info?.initials ?? player.initials,
                    size: 46
                )

                Text(info?.firstName ?? player.firstName)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)

                if let detail = ageAndRanking {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

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
    private var ageAndRanking: String? {
        var parts: [String] = []
        if let age = info?.age, age > 0 { parts.append("\(age) ans") }
        if let ranking = info?.ranking(for: sport) { parts.append(ranking) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [info?.firstName ?? player.firstName]
        if let ageAndRanking { parts.append(ageAndRanking) }
        if showsSide { parts.append("côté \(player.side.displayName)") }
        return parts.joined(separator: ", ")
    }
}

/// Place libre : un bouton « + » tapable.
struct EmptySlotView: View {
    let sport: Sport
    let onTap: () -> Void

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
