//
//  ClubDirectoryService.swift
//  iClub
//
//  Accès aux autres membres du club, exclusivement par fonctions dédiées.
//
//  Les règles de sécurité interdisent à un membre de lire les fiches des
//  autres : `profiles` et `club_members` portent e-mail, téléphone et date de
//  naissance. Deux fonctions déployées côté base couvrent les seuls usages
//  légitimes : chercher un co-équipier, et afficher photo et classement des
//  participants d'une réservation. Il n'y a pas d'autre chemin à emprunter.
//
//  Place dans l'application
//    Recherche de partenaires du tunnel de réservation (`MemberSearchSheet` :
//    partenaires récents et recherche), nouveau message (`NewMessageView`),
//    fiche d'un membre (`MemberCardSheet`), et photos et classements des
//    joueurs dans l'accueil, les réservations, les parties ouvertes, les cours
//    et l'espace entraîneur (`rosterInfo`).
//
//  Tables et fonctions SQL
//    - `search_club_members(target_club_id, q)` et
//      `get_club_roster_info(target_profile_ids)` : fonctions `security
//      definer`, limitées aux clubs de l'appelant.
//    - Tables `reservations` et `reservation_participants` (partenaires
//      récents), lisibles par les membres du club.
//    - Tables `club_members` et `memberships` (statut d'adhésion des
//      partenaires récents) : voir l'avertissement de
//      `profilesWithActiveMembership`.
//    Aucune écriture.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet) ; les lectures
//    indépendantes partent en parallèle (`async let`). Aucun cache.
//

import Foundation
import Supabase

/// Réservation dont on ne retient que les co-participants, pour reconstituer
/// les partenaires récents.
nonisolated struct RecentPartnerRow: Decodable, Sendable {
    /// Participants joints (`reservation_participants`).
    let participants: [Participant]

    /// Participant joint, réduit à son profil.
    nonisolated struct Participant: Decodable, Sendable {
        /// `profile_id`, `nil` pour un invité.
        let profileId: UUID?

        /// Correspondance avec la colonne SQL.
        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
        }
    }

    /// Correspondance avec la jointure.
    enum CodingKeys: String, CodingKey {
        case participants = "reservation_participants"
    }

    /// Sélection PostgREST ; `id` et `created_at` sont demandés mais non
    /// décodés (le tri se fait dans la requête).
    static let columns = "id, created_at, reservation_participants(profile_id)"
}

/// Ligne de `club_members` réduite au lien appartenance et profil.
nonisolated struct ClubMemberLink: Decodable, Sendable {
    /// `club_members.id`.
    let id: UUID
    /// `club_members.profile_id`.
    let profileId: UUID

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
    }
}

/// Ligne de `memberships` réduite à l'appartenance qu'elle couvre.
nonisolated struct MembershipStatusRow: Decodable, Sendable {
    /// `memberships.club_member_id`.
    let clubMemberId: UUID

    /// Correspondance avec la colonne SQL.
    enum CodingKeys: String, CodingKey {
        case clubMemberId = "club_member_id"
    }
}

/// Annuaire du club : recherche de membres, partenaires récents, fiches
/// réduites des joueurs.
enum ClubDirectoryService {

    /// Nombre de partenaires récents proposés au-dessus de la recherche.
    nonisolated static let recentPartnerCount = 5

    /// Derniers membres ajoutés à une réservation ou à une partie que j'ai
    /// créée, du plus récent au plus ancien, sans doublon.
    ///
    /// Reconstitué depuis `reservations` plutôt que mémorisé sur l'appareil :
    /// la liste suit ainsi l'activité faite depuis le web, et survit à une
    /// réinstallation.
    ///
    /// Tolérant à l'échec de bout en bout : sans partenaires récents, la
    /// recherche fonctionne exactement comme avant.
    ///
    /// Limite connue : la base offre déjà ce calcul côté serveur,
    /// `get_recent_partners(target_club_id, limit_n)`, qui écarte aussi les
    /// comptes d'enfants et les comptes supprimés et calcule le statut
    /// d'adhésion avec les droits voulus. L'app ne l'utilise pas.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - profileId: membre connecté, créateur des réservations parcourues.
    ///   - limit: nombre maximal de partenaires.
    /// - Returns: les partenaires, avec nom et photo ; liste vide en cas d'échec.
    static func recentPartners(
        clubId: UUID,
        profileId: UUID,
        limit: Int = recentPartnerCount
    ) async -> [MemberSearchResult] {
        do {
            let rows: [Lenient<RecentPartnerRow>] = try await Supa.client
                .from("reservations")
                .select(RecentPartnerRow.columns)
                .eq("club_id", value: clubId.uuidString)
                .eq("created_by", value: profileId.uuidString)
                .order("created_at", ascending: false)
                // Plafonné : cinq partenaires distincts se trouvent bien avant
                // la quarantième réservation, et cela borne la requête.
                .limit(40)
                .execute()
                .value

            var ordered: [UUID] = []
            // L'utilisateur figure dans ses propres réservations : on l'écarte
            // dès le départ, comme le fait déjà `search_club_members`.
            var seen: Set<UUID> = [profileId]

            // Parcours du plus récent au plus ancien ; premier vu, premier gardé.
            for row in rows.compactValues() {
                for participant in row.participants {
                    // Un invité n'a pas de `profile_id` : il n'est pas
                    // proposable, il n'a pas de fiche au club.
                    guard let id = participant.profileId, !seen.contains(id) else { continue }
                    seen.insert(id)
                    ordered.append(id)
                    if ordered.count == limit { break }
                }
                if ordered.count == limit { break }
            }

            guard !ordered.isEmpty else { return [] }

            // Figé dans un `let` avant les appels concurrents : capturer le
            // `var` dans un `async let` serait une course, et une erreur en
            // mode Swift 6.
            let partnerIds = ordered

            // Nom et photo d'un côté, statut d'adhésion de l'autre, en parallèle.
            async let rosterTask = rosterInfo(profileIds: partnerIds)
            async let activeTask = profilesWithActiveMembership(clubId: clubId)
            let roster = await rosterTask
            let active = await activeTask

            // Un partenaire que `get_club_roster_info` ne rend pas (plus membre
            // du club) est écarté ; l'ordre de récence est conservé.
            return partnerIds.compactMap { id in
                guard let info = roster[id] else { return nil }
                return MemberSearchResult(
                    profileId: id,
                    nom: info.nom,
                    prenom: info.prenom,
                    avatarUrl: info.avatarUrl,
                    hasActiveMembership: active.contains(id)
                )
            }
        } catch {
            return []
        }
    }

    /// Profils ayant au moins une adhésion `a_jour`.
    ///
    /// Ici un simple booléen suffit, donc l'existence d'une ligne active
    /// répond à la question, contrairement à l'affichage d'une *date* de
    /// validité, qui exige de trier par `created_at` décroissant pour prendre
    /// la plus récente des lignes `a_jour`.
    ///
    /// Attention : cette lecture passe par le client du membre, donc par la RLS.
    /// Un adhérent qui n'est pas administrateur ne lit que sa propre ligne
    /// `club_members` et ses propres adhésions (`club_members_select`,
    /// `memberships_select`) : l'ensemble rendu ne contient au plus que
    /// lui-même, déjà écarté des partenaires. Les partenaires récents sont donc
    /// tous marqués « Sans adhésion active », à tort. La lecture de `memberships`
    /// ne filtre pas non plus sur le club. Le web fait ce calcul avec la clé de
    /// service, et la fonction `get_recent_partners` le fait côté base.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: profils couverts par une adhésion `a_jour` ; vide en cas d'échec.
    private static func profilesWithActiveMembership(clubId: UUID) async -> Set<UUID> {
        do {
            // Appartenances du club (identifiant d'appartenance et profil).
            async let membersTask: [Lenient<ClubMemberLink>] = Supa.client
                .from("club_members")
                .select("id, profile_id")
                .eq("club_id", value: clubId.uuidString)
                .execute()
                .value

            // Appartenances couvertes par une adhésion « à jour ».
            async let membershipsTask: [Lenient<MembershipStatusRow>] = Supa.client
                .from("memberships")
                .select("club_member_id")
                .eq("statut", value: MembershipRow.activeStatus)
                .execute()
                .value

            let members = try await membersTask.compactValues()
            let activeMemberIds = Set(try await membershipsTask.compactValues().map(\.clubMemberId))

            // Jointure faite ici : appartenances actives ramenées à leur profil.
            return Set(
                members
                    .filter { activeMemberIds.contains($0.id) }
                    .map(\.profileId)
            )
        } catch {
            return []
        }
    }

    /// Recherche d'adhérents par prénom ou nom. La fonction plafonne à 8
    /// résultats, exclut l'utilisateur connecté et ne renvoie que les membres
    /// du club : rien de tout cela n'est à refaire ici.
    /// (Elle écarte aussi les comptes d'enfants et les comptes supprimés, et
    /// trie par prénom puis nom.)
    ///
    /// - Parameters:
    ///   - clubId: club où chercher.
    ///   - query: texte saisi ; moins de 2 caractères utiles, aucune requête.
    /// - Returns: au plus 8 membres.
    /// - Throws: l'erreur brute de la requête.
    static func searchMembers(clubId: UUID, query: String) async throws -> [MemberSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MemberSearchResult.minimumQueryLength else { return [] }

        let rows: [Lenient<MemberSearchResult>] = try await Supa.client
            .rpc("search_club_members", params: MemberSearchParams(targetClubId: clubId, q: trimmed))
            .execute()
            .value

        return rows.compactValues()
    }

    /// Photo et classements des participants d'une réservation, indexés par
    /// profil. Tolérant : un échec prive l'écran de détail des classements,
    /// jamais de la liste des participants.
    ///
    /// - Parameter profileIds: profils à décrire ; vide, aucune requête.
    /// - Returns: une fiche par profil membre d'un club de l'appelant ; en cas
    ///   de doublon (profil membre de deux clubs de l'appelant), la première
    ///   ligne est gardée. Dictionnaire vide en cas d'échec.
    static func rosterInfo(profileIds: [UUID]) async -> [UUID: RosterInfoRow] {
        guard !profileIds.isEmpty else { return [:] }

        do {
            let rows: [Lenient<RosterInfoRow>] = try await Supa.client
                .rpc("get_club_roster_info", params: RosterInfoParams(targetProfileIds: profileIds))
                .execute()
                .value

            return Dictionary(
                rows.compactValues().map { ($0.profileId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            return [:]
        }
    }
}
