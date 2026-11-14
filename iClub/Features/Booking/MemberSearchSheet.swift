//
//  MemberSearchSheet.swift
//  iClub
//
//  Recherche d'un adhérent à ajouter à la partie.
//
//  La recherche passe par `search_club_members` : un membre n'a pas le droit de
//  lire les fiches des autres. La fonction ne renvoie pas l'e-mail : un membre
//  n'a pas à découvrir les adresses de ses co-adhérents par une recherche.
//
//  Place dans l'application
//    Feuille ouverte par le bouton « Adhérent » de l'écran des joueurs du
//    tunnel de réservation (`ParticipantsView`). Toucher un membre l'ajoute au
//    brouillon et ferme la feuille. Ce fichier déclare aussi `MemberAvatar`,
//    la pastille photo ou initiales utilisée dans toute l'application.
//
//  Données
//    - Avant toute frappe : les partenaires récents
//      (`ClubDirectoryService.recentPartners`, reconstitués depuis les
//      réservations créées par la personne).
//    - Dès deux caractères : `search_club_members` (fonction SQL en
//      `security definer`), qui ne rend que des membres du club de l'appelant,
//      jamais l'appelant lui-même, ni les comptes d'enfants ni les comptes
//      supprimés, au plus 8, triés par prénom puis nom.
//    - Âge et classements : second appel à `get_club_roster_info`, cloisonné
//      aux clubs de l'appelant.
//
//  États
//    Indication tant que la saisie est trop courte (ou liste des récents),
//    squelettes pendant la recherche, « Aucun adhérent trouvé », message
//    d'erreur en tête en cas d'échec.
//
//  Points d'attention
//    - Attention : la mention « Sans adhésion active » des partenaires récents
//      vient de `ClubDirectoryService.profilesWithActiveMembership`, qui lit
//      `club_members` et `memberships` directement ; les politiques RLS de ces
//      tables ne montrent à un membre ordinaire que ses propres lignes. D'après
//      ces politiques, un partenaire récent est donc toujours signalé « Sans
//      adhésion active » pour un membre qui n'est pas administrateur.
//    - Quand on agit pour un enfant, la fonction exclut toujours le compte
//      connecté (le parent), et les partenaires récents sont cherchés parmi
//      les réservations créées par l'enfant, donc en pratique aucun.
//

import SwiftUI

/// Feuille de recherche d'un adhérent du club, avec les partenaires récents.
struct MemberSearchSheet: View {
    /// Club dans lequel chercher.
    let clubId: UUID
    /// Utilisateur connecté, pour retrouver ses partenaires récents.
    /// En pratique le profil actif : soi, ou l'enfant sélectionné.
    let myProfileId: UUID
    /// Sport de la réservation en cours : détermine lequel des deux classements
    /// est affiché. Aucun en pickleball, le club n'y tient pas de classement.
    let sport: Sport
    /// Profils déjà dans la partie, écartés des résultats.
    let excluded: Set<UUID>
    /// Appelé avec le membre choisi, juste avant la fermeture de la feuille.
    let onSelect: (MemberSearchResult) -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Texte du champ de recherche.
    @State private var query = ""
    /// Résultats de la dernière recherche.
    @State private var results: [MemberSearchResult] = []
    /// Classements des résultats, indexés par profil. `MemberSearchResult` ne
    /// les décode pas (la fonction `search_club_members` les renvoie pourtant
    /// depuis la migration 20260923180000) : ils sont relus par un second appel
    /// à `get_club_roster_info`.
    @State private var roster: [UUID: RosterInfoRow] = [:]
    /// Vrai pendant l'appel à `search_club_members`.
    @State private var isSearching = false
    /// Message d'erreur de la dernière recherche, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Derniers membres ajoutés à mes réservations, proposés avant toute frappe.
    @State private var recents: [MemberSearchResult] = []

    /// Résultats, sans les joueurs déjà dans la partie.
    private var visibleResults: [MemberSearchResult] {
        results.filter { !excluded.contains($0.profileId) }
    }

    /// Ceux déjà dans la partie n'ont plus rien à faire dans les raccourcis.
    private var visibleRecents: [MemberSearchResult] {
        recents.filter { !excluded.contains($0.profileId) }
    }

    /// Feuille avec champ de recherche dans la barre : erreur éventuelle, puis
    /// récents ou résultats.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Erreur de recherche (réseau, fonction indisponible).
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
                // Fermeture sans rien ajouter.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Prénom ou nom")
            // `.task(id:)` annule la recherche précédente à chaque frappe : le
            // délai n'est donc jamais atteint tant que l'utilisateur tape.
            .task(id: query) { await search() }
            // Partenaires récents, chargés une fois à l'ouverture.
            .task { await loadRecents() }
        }
    }

    /// Contenu sous le champ, selon la saisie et l'état de la recherche.
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
            // Recherche en cours : trois rangées fantômes.
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(height: 62, cornerRadius: Radius.inner)
                }
            }
        } else if visibleResults.isEmpty {
            // Aucun résultat, ou seulement des joueurs déjà dans la partie.
            hint("Aucun adhérent trouvé pour « \(trimmed) ».")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visibleResults) { member in
                    row(member)
                }
            }
        }
    }

    /// Section « Récents » : les partenaires récents, puis une invitation à
    /// chercher quelqu'un d'autre.
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

    /// Rangée d'un membre : photo, nom, âge et classement, mention d'adhésion
    /// expirée, et « + ». Le tap ajoute le membre et ferme la feuille.
    ///
    /// - Parameter member: membre affiché.
    /// - Returns: le bouton de la rangée.
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

                    // « 34 ans · classement tennis 15/2 », dès que le second
                    // appel est revenu.
                    if let subtitle = subtitle(for: member) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    // Cas réel : membre du club dont l'adhésion a expiré. Il
                    // devra régler sa part, d'où la mention.
                    // (Dans l'app, ce membre ne coûte pourtant rien au
                    // récapitulatif : voir BookingDraft.swift.)
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
    /// affiché que si la base le fournit (voir `RosterInfoRow`).
    ///
    /// - Parameter member: membre concerné.
    /// - Returns: « 34 ans · classement tennis 15/2 », « Sans classement
    ///   padel »..., ou `nil` faute d'information.
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

        // Première lettre en capitale (« Sans classement... » sans âge).
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Texte d'indication gris, aligné à gauche.
    ///
    /// - Parameter message: texte à afficher.
    /// - Returns: la vue du texte.
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
    ///
    /// En pickleball, l'appel des fiches n'est pas fait pour les récents (pas
    /// de classement) : leur âge n'est donc pas affiché, contrairement aux
    /// résultats de recherche. Limite connue : effacer la recherche vide
    /// `roster` (voir `search`), et les récents perdent alors leur sous-titre.
    private func loadRecents() async {
        let partners = await ClubDirectoryService.recentPartners(
            clubId: clubId,
            profileId: myProfileId
        )
        // Feuille fermée entre-temps : rien à publier.
        guard !Task.isCancelled else { return }
        recents = partners

        guard sport != .pickleball, !partners.isEmpty else { return }
        let info = await ClubDirectoryService.rosterInfo(profileIds: partners.map(\.profileId))
        guard !Task.isCancelled else { return }
        roster.merge(info) { _, new in new }
    }

    /// Recherche des adhérents correspondant à la saisie, après un délai de
    /// 250 ms, puis lecture de leurs âges et classements.
    ///
    /// Sous deux caractères, rien n'est demandé : résultats, fiches et erreur
    /// sont effacés.
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
            // Une frappe plus récente a pris le relais : ses fiches priment.
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
///
/// Utilisée dans le tunnel de réservation, l'accueil, les réservations et les
/// parties ouvertes. L'image est chargée par `AsyncImage` (cache partagé
/// `URLCache.shared`) ; tant qu'elle n'est pas arrivée, ou en cas d'échec, les
/// initiales s'affichent sur un disque bleu pâle.
struct MemberAvatar: View {
    /// Adresse de la photo (`profiles.avatar_url`), `nil` sans photo.
    let url: URL?
    /// Initiales de repli (« CR », ou « ? »).
    let initials: String
    /// Diamètre en points, 40 par défaut.
    var size: CGFloat = 40

    /// Disque de `size` points : photo, ou initiales.
    var body: some View {
        Group {
            if let url {
                // Photo si elle se charge, initiales sinon.
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

    /// Disque bleu pâle portant les initiales, à 38 % du diamètre.
    private var placeholder: some View {
        ZStack {
            Brand.navy700.opacity(0.12)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.navy700)
        }
    }
}
