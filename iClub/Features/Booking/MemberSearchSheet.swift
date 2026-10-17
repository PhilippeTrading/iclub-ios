//
//  MemberSearchSheet.swift
//  iClub
//
//  Recherche d'un adhérent à ajouter à la partie.
//
//  La recherche passe par `search_club_members` : un membre n'a pas le droit de
//  lire les fiches des autres. La fonction ne renvoie pas l'e-mail — un membre
//  n'a pas à découvrir les adresses de ses co-adhérents par une recherche.
//

import SwiftUI

struct MemberSearchSheet: View {
    let clubId: UUID
    /// Utilisateur connecté, pour retrouver ses partenaires récents.
    let myProfileId: UUID
    /// Sport de la réservation en cours : détermine lequel des deux classements
    /// est affiché. Aucun en pickleball, le club n'y tient pas de classement.
    let sport: Sport
    /// Profils déjà dans la partie, écartés des résultats.
    let excluded: Set<UUID>
    let onSelect: (MemberSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MemberSearchResult] = []
    /// Classements des résultats, indexés par profil. `search_club_members` ne
    /// les renvoie pas : il faut un second appel à `get_club_roster_info`.
    @State private var roster: [UUID: RosterInfoRow] = [:]
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// Derniers membres ajoutés à mes réservations, proposés avant toute frappe.
    @State private var recents: [MemberSearchResult] = []

    private var visibleResults: [MemberSearchResult] {
        results.filter { !excluded.contains($0.profileId) }
    }

    /// Ceux déjà dans la partie n'ont plus rien à faire dans les raccourcis.
    private var visibleRecents: [MemberSearchResult] {
        recents.filter { !excluded.contains($0.profileId) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }

                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Ajouter un adhérent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Prénom ou nom")
            // `.task(id:)` annule la recherche précédente à chaque frappe : le
            // délai n'est donc jamais atteint tant que l'utilisateur tape.
            .task(id: query) { await search() }
            .task { await loadRecents() }
        }
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count < MemberSearchResult.minimumQueryLength {
            // Avant toute frappe, les partenaires récents évitent d'avoir à
            // retaper un nom déjà saisi la semaine dernière.
            if !visibleRecents.isEmpty {
                recentsSection
            } else {
                hint("Saisis au moins \(MemberSearchResult.minimumQueryLength) caractères pour lancer la recherche.")
            }
        } else if isSearching {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(height: 62, cornerRadius: Radius.inner)
                }
            }
        } else if visibleResults.isEmpty {
            hint("Aucun adhérent trouvé pour « \(trimmed) ».")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visibleResults) { member in
                    row(member)
                }
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Récents")
                .metaLabelStyle()
                .padding(.top, 2)

            ForEach(visibleRecents) { member in
                row(member)
            }

            Text("Ou cherche un autre adhérent par prénom ou nom.")
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)
                .padding(.top, 2)
        }
    }

    private func row(_ member: MemberSearchResult) -> some View {
        Button {
            onSelect(member)
            Haptics.selection()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                MemberAvatar(
                    url: member.avatarUrl.flatMap(URL.init(string:)),
                    initials: member.initials,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(member.displayName)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)

                    if let subtitle = subtitle(for: member) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    // Cas réel : membre du club dont l'adhésion a expiré. Il
                    // devra régler sa part, d'où la mention.
                    if !member.hasActiveMembership {
                        Text("Sans adhésion active")
                            .font(.caption)
                            .foregroundStyle(Brand.warning)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.navy700)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: Radius.inner)
        }
        .buttonStyle(.plain)
    }

    /// Âge et classement du sport réservé, sous le nom.
    ///
    /// Rien tant que le second appel n'est pas revenu : une ligne qui apparaît
    /// vaut mieux qu'une ligne qui change de texte sous les yeux. L'âge n'est
    /// affiché que si la base le fournit — voir `RosterInfoRow`.
    private func subtitle(for member: MemberSearchResult) -> String? {
        guard let info = roster[member.profileId] else { return nil }

        var parts: [String] = []
        if let ageLabel = info.ageLabel { parts.append(ageLabel) }

        // Le club ne tient pas de classement en pickleball.
        if sport != .pickleball {
            let name = sport.displayName.lowercased()
            if let ranking = info.ranking(for: sport) {
                parts.append("classement \(name) \(ranking)")
            } else {
                parts.append("sans classement \(name)")
            }
        }

        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private func hint(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Brand.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    /// Chargés une fois à l'ouverture. Leurs classements viennent du même
    /// appel que la recherche, donc l'affichage est identique dans les deux
    /// sections.
    private func loadRecents() async {
        let partners = await ClubDirectoryService.recentPartners(
            clubId: clubId,
            profileId: myProfileId
        )
        guard !Task.isCancelled else { return }
        recents = partners

        guard sport != .pickleball, !partners.isEmpty else { return }
        let info = await ClubDirectoryService.rosterInfo(profileIds: partners.map(\.profileId))
        guard !Task.isCancelled else { return }
        roster.merge(info) { _, new in new }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MemberSearchResult.minimumQueryLength else {
            results = []
            roster = [:]
            errorMessage = nil
            return
        }

        // Léger délai avant d'interroger la base, plutôt qu'un appel par frappe.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        isSearching = true
        do {
            let found = try await ClubDirectoryService.searchMembers(clubId: clubId, query: trimmed)
            results = found
            errorMessage = nil
            isSearching = false

            // Les noms sont affichés sans attendre : le second appel ne doit pas
            // retarder la liste. Il est tolérant à l'échec. Lancé aussi en
            // pickleball, où il n'y a pas de classement mais où l'âge compte.
            guard !found.isEmpty else { return }
            let info = await ClubDirectoryService.rosterInfo(profileIds: found.map(\.profileId))
            guard !Task.isCancelled else { return }
            roster = info
        } catch {
            results = []
            roster = [:]
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }
}

/// Photo de profil, avec repli sur les initiales.
struct MemberAvatar: View {
    let url: URL?
    let initials: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var placeholder: some View {
        ZStack {
            Brand.navy700.opacity(0.12)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.navy700)
        }
    }
}
