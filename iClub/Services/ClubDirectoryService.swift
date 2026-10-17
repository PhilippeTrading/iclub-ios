//
//  ClubDirectoryService.swift
//  iClub
//
//  Accès aux autres membres du club, exclusivement par fonctions dédiées.
//
//  Les règles de sécurité interdisent à un membre de lire les fiches des
//  autres : `profiles` et `club_members` portent e-mail, téléphone et date de
//  naissance. Deux fonctions déployées côté base couvrent les seuls usages
//  légitimes — chercher un co-équipier, et afficher photo et classement des
//  participants d'une réservation. Il n'y a pas d'autre chemin à emprunter.
//

import Foundation
import Supabase

/// Réservation dont on ne retient que les co-participants, pour reconstituer
/// les partenaires récents.
nonisolated struct RecentPartnerRow: Decodable, Sendable {
    let participants: [Participant]

    nonisolated struct Participant: Decodable, Sendable {
        let profileId: UUID?

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case participants = "reservation_participants"
    }

    static let columns = "id, created_at, reservation_participants(profile_id)"
}

nonisolated struct ClubMemberLink: Decodable, Sendable {
    let id: UUID
    let profileId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
    }
}

nonisolated struct MembershipStatusRow: Decodable, Sendable {
    let clubMemberId: UUID

    enum CodingKeys: String, CodingKey {
        case clubMemberId = "club_member_id"
    }
}

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

            async let rosterTask = rosterInfo(profileIds: partnerIds)
            async let activeTask = profilesWithActiveMembership(clubId: clubId)
            let roster = await rosterTask
            let active = await activeTask

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
    /// répond à la question — contrairement à l'affichage d'une *date* de
    /// validité, qui exige de trier par `created_at` décroissant pour prendre
    /// la plus récente des lignes `a_jour`.
    private static func profilesWithActiveMembership(clubId: UUID) async -> Set<UUID> {
        do {
            async let membersTask: [Lenient<ClubMemberLink>] = Supa.client
                .from("club_members")
                .select("id, profile_id")
                .eq("club_id", value: clubId.uuidString)
                .execute()
                .value

            async let membershipsTask: [Lenient<MembershipStatusRow>] = Supa.client
                .from("memberships")
                .select("club_member_id")
                .eq("statut", value: MembershipRow.activeStatus)
                .execute()
                .value

            let members = try await membersTask.compactValues()
            let activeMemberIds = Set(try await membershipsTask.compactValues().map(\.clubMemberId))

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
    /// du club — rien de tout cela n'est à refaire ici.
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
