//
//  OpenGameCard.swift
//  iClub
//
//  Une partie ouverte dans la liste.
//
//  En **double**, deux colonnes ÉQUIPE A et ÉQUIPE B, deux places chacune.
//  En **simple**, une seule rangée de deux places, sans notion d'équipe.
//

import SwiftUI

struct OpenGameCard: View {
    let game: OpenGame
    let roster: [UUID: RosterInfoRow]
    /// Profil connecté. La carte en déduit seule s'il est hôte, joueur ou
    /// extérieur — plutôt que de recevoir plusieurs booléens qui pourraient se
    /// contredire.
    let myProfileId: UUID?
    let onSelectPlayer: (OpenGame.Player) -> Void
    /// Place libre tapée, avec l'équipe visée (`nil` en simple).
    let onSelectFreeSlot: (Team?) -> Void
    let onJoin: () -> Void
    /// Sortie de la partie : annulation pour l'hôte, simple départ sinon.
    let onLeave: () -> Void

    private var role: OpenGame.Role { game.role(for: myProfileId) }

    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                header
                badges
                schedule

                if game.usesTeams {
                    teamColumns
                } else {
                    singlesRow
                }

                if game.isFacingAutomaticCancellation {
                    cancellationWarning
                }

                actionButton
            }
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 12) {
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

                Text(game.levelAndFormatLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            BrandChip(
                title: game.freeSlotsLabel,
                tint: game.isFull ? Brand.textSecondary : game.sport.accent
            )
            .fixedSize()
        }
    }

    // MARK: - Badges

    @ViewBuilder
    private var badges: some View {
        let items = badgeItems

        if !items.isEmpty {
            // Une partie loisir et mixte n'a aucun badge : c'est le cas
            // courant, et la carte reste dégagée.
            HStack(spacing: 6) {
                ForEach(items, id: \.title) { item in
                    BrandChip(title: item.title, systemImage: item.symbol, tint: item.tint)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var badgeItems: [(title: String, symbol: String?, tint: Color)] {
        var items: [(String, String?, Color)] = []

        if let badge = game.ambiance.badge {
            items.append((badge, "flame", Brand.clay800))
        }
        if let badge = game.mixite.badge {
            items.append((badge, "person.2", Brand.navy700))
        }
        if game.isFacingAutomaticCancellation {
            items.append(("Annulation imminente", "exclamationmark.triangle.fill", Brand.error))
        }

        return items.map { (title: $0.0, symbol: $0.1, tint: $0.2) }
    }

    // MARK: - Créneau

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

    /// `Grid` et non deux `VStack` côte à côte : une grille impose une hauteur
    /// commune à toutes les cellules d'une même rangée. Avec deux colonnes
    /// indépendantes, une vignette de joueur — plus haute qu'un « + » vide —
    /// décalait toute la colonne d'en face.
    private var teamColumns: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                ForEach(Team.allCases) { team in
                    Text(team.displayName)
                        .metaLabelStyle()
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<2, id: \.self) { index in
                GridRow {
                    ForEach(Team.allCases) { team in
                        slot(for: team, at: index)
                    }
                }
            }
        }
    }

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

    @ViewBuilder
    private func slot(for team: Team?, at index: Int) -> some View {
        let occupants = team.map { game.players(in: $0) } ?? game.players

        if index < occupants.count {
            let player = occupants[index]
            PlayerSlotView(
                player: player,
                info: roster[player.profileId],
                sport: game.sport,
                showsSide: game.usesSides,
                onTap: { onSelectPlayer(player) }
            )
        } else {
            EmptySlotView(sport: game.sport) { onSelectFreeSlot(team) }
        }
    }

    // MARK: - Annulation imminente

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
        .background(Brand.error.opacity(0.08), in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }

    // MARK: - Action

    /// Un seul bouton, trois libellés selon la place de l'utilisateur :
    /// « Rejoindre » pour un extérieur, « Quitter la partie » pour un joueur
    /// inscrit, « Annuler la partie » pour l'hôte.
    ///
    /// Les deux sorties passent en teinte d'alerte : ce ne sont pas des actions
    /// qu'on déclenche par mégarde, et l'annulation touche tous les joueurs.
    private var actionButton: some View {
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
            .foregroundStyle(isLeaving ? Brand.error : Color.white)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isLeaving ? Brand.error.opacity(0.10) : game.sport.accent)
            }
            .overlay {
                if isLeaving {
                    RoundedRectangle.squircle(Radius.chip)
                        .strokeBorder(Brand.error.opacity(0.30), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    func roster(_ id: UUID, _ prenom: String, _ age: Int, _ padel: String) -> RosterInfoRow {
        var json = "{\"profile_id\":\"" + id.uuidString + "\""
        json += ",\"prenom\":\"" + prenom + "\",\"nom\":\"Test\",\"avatar_url\":null"
        json += ",\"age\":" + String(age)
        json += ",\"classement_tennis\":\"30/1\",\"classement_padel\":" + padel + "}"
        return try! JSONDecoder().decode(RosterInfoRow.self, from: Data(json.utf8))
    }

    let marieId = UUID(), camilleId = UUID()
    let marie = OpenGame.Player(profileId: marieId, displayName: "Marie Dupont", team: .a, side: .gauche)
    let camille = OpenGame.Player(profileId: camilleId, displayName: "Camille Roux", team: .b, side: .droite)

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

    let padelDouble = OpenGame(
        id: UUID(), date: Date.now.addingTimeInterval(86400 * 2),
        slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 90),
        sport: .padel, courtName: "Padel 1", format: .double, mixite: .femmes,
        ambiance: .competitif, niveauMin: "4.0", niveauMax: "5.0",
        hostId: marieId, isCancelled: false, players: [marie, camille]
    )

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
