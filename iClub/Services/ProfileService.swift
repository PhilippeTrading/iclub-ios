//
//  ProfileService.swift
//  iClub
//
//  Assemble le `SessionProfile` à partir de `profiles`, `club_members`, `clubs`
//  et `memberships`.
//
//  Deux règles issues de bugs déjà rencontrés côté web :
//
//  1. `memberships` est trié par `created_at` décroissant *avant* de filtrer sur
//     `statut = 'a_jour'` — un membre a plusieurs lignes historiques.
//  2. Aucun champ optionnel ou récent ne doit bloquer le chargement de session :
//     nom du club et adhésion sont chargés par des appels séparés tolérants à
//     l'échec, et la lecture de `profiles` retombe sur un jeu de colonnes
//     minimal si une colonne manque.
//

import Foundation
import Supabase

enum RankingError: LocalizedError {
    /// Refus de la base, déjà rédigé : « Classement tennis invalide ».
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}

enum SessionProfileError: LocalizedError {
    case noClubMembership
    case profileUnavailable
    /// L'écriture n'a touché aucune ligne : refusée par les règles de sécurité,
    /// ou profil introuvable.
    case updateRejected

    var errorDescription: String? {
        switch self {
        case .noClubMembership:
            "Ton compte n'est rattaché à aucun club. Contacte le secrétariat pour finaliser ton inscription."
        case .profileUnavailable:
            "Impossible de charger ton profil pour le moment."
        case .updateRejected:
            "Tes informations n'ont pas pu être enregistrées. Réessaie, et contacte le club si cela persiste."
        }
    }
}

/// Paramètre des deux fonctions de classement.
///
/// L'encodage est écrit à la main : l'encodeur synthétisé de Swift utilise
/// `encodeIfPresent` pour une propriété optionnelle et **omettrait la clé**
/// quand la valeur est nulle. La fonction recevrait alors un paramètre
/// manquant au lieu d'un `null`, et n'effacerait rien.
nonisolated struct RankingParam<Value: Encodable & Sendable>: Encodable, Sendable {
    let newClassement: Value?

    enum CodingKeys: String, CodingKey {
        case newClassement = "new_classement"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let newClassement {
            try container.encode(newClassement, forKey: .newClassement)
        } else {
            try container.encodeNil(forKey: .newClassement)
        }
    }
}

enum ProfileService {

    // MARK: - Classements

    /// Les classements vivent sur `club_members`, que le membre n'a pas le
    /// droit de modifier directement — c'est ce qui l'empêche de se nommer
    /// administrateur. Ces deux fonctions ouvrent exactement la porte
    /// nécessaire, et valident la valeur reçue côté base.
    ///
    /// - Parameter value: `nil` pour effacer le classement.
    static func updateTennisRanking(_ value: String?) async throws {
        try await callRanking("update_my_tennis_ranking", RankingParam(newClassement: value))
    }

    static func updatePadelRanking(_ value: Double?) async throws {
        try await callRanking("update_my_padel_ranking", RankingParam(newClassement: value))
    }

    private static func callRanking(_ function: String, _ params: some Encodable & Sendable) async throws {
        do {
            try await Supa.client.rpc(function, params: params).execute()
        } catch {
            // La base refuse une valeur hors échelle avec un message déjà
            // rédigé en français : on l'affiche tel quel.
            if let postgrest = error as? PostgrestError, postgrest.code == "P0001" {
                throw RankingError.rejected(postgrest.message)
            }
            throw error
        }
    }

    static func loadSessionProfile(userId: UUID, email: String) async throws -> SessionProfile {
        let profile = try await fetchProfile(userId: userId)
        let member = try await fetchClubMember(userId: userId)

        // Non bloquants : un échec ici ne doit jamais empêcher la connexion.
        let clubName = await fetchClubName(clubId: member.clubId)
        let membership = await fetchActiveMembership(clubMemberId: member.id)

        let nom = profile.nom ?? ""
        let prenom = profile.prenom
        let resolvedEmail = profile.email ?? email

        let period: (debut: Date, fin: Date)? = {
            guard let membership,
                  let debut = SupabaseDate.parse(membership.dateDebut),
                  let fin = SupabaseDate.parse(membership.dateFin)
            else { return nil }
            return (debut, fin)
        }()

        let details: (formule: String, montant: Double)? = {
            guard let membership, let formule = membership.formule else { return nil }
            return (formule, membership.montant ?? 0)
        }()

        return SessionProfile(
            id: profile.id,
            clubMemberId: member.id,
            email: resolvedEmail,
            nom: nom,
            prenom: prenom,
            displayName: displayName(prenom: prenom, nom: nom, email: resolvedEmail),
            avatarUrl: profile.avatarUrl.flatMap(URL.init(string:)),
            telephone: profile.telephone,
            dateNaissance: SupabaseDate.parse(profile.dateNaissance),
            sexe: profile.sexe.flatMap { Sexe(rawValue: $0.uppercased()) },
            role: member.role ?? "membre",
            isAdmin: member.isAdmin ?? false,
            clubId: member.clubId,
            clubName: clubName ?? "Mon club",
            classementTennis: member.classementTennis,
            classementPadel: member.classementPadel,
            hasActiveMembership: membership != nil,
            activeMembershipPeriod: period,
            activeMembershipDetails: details
        )
    }

    // MARK: - profiles

    private static func fetchProfile(userId: UUID) async throws -> ProfileRow {
        do {
            return try await Supa.client
                .from("profiles")
                .select(ProfileRow.allColumns)
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
        } catch {
            // Une colonne récente peut manquer si une migration n'est pas encore
            // appliquée en base : on ne bloque pas la connexion de tout le monde
            // pour autant, on recharge le strict nécessaire.
            return try await Supa.client
                .from("profiles")
                .select(ProfileRow.coreColumns)
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
        }
    }

    // MARK: - Mise à jour du profil

    /// Écrit les informations personnelles modifiables depuis l'espace profil.
    ///
    /// Le numéro est normalisé avant écriture, et refusé s'il est invalide :
    /// la base ne doit contenir que des numéros au même format que ceux du web.
    ///
    /// La ligne modifiée est redemandée par `.select()`, et son absence traitée
    /// comme une erreur. Sans cela PostgREST répond `200` sans corps même
    /// lorsque *aucune* ligne n'a été touchée — une écriture refusée par les
    /// règles de sécurité serait indiscernable d'un succès, et l'écran
    /// annoncerait un enregistrement qui n'a pas eu lieu.
    static func updatePersonalInfo(
        profileId: UUID,
        prenom: String,
        nom: String,
        telephone: String,
        dateNaissance: Date,
        sexe: Sexe
    ) async throws {
        guard PhoneNumber.isValid(telephone) else {
            throw AuthServiceError.invalidPhone
        }

        let payload = ProfileUpdate(
            prenom: prenom.trimmingCharacters(in: .whitespaces),
            nom: nom.trimmingCharacters(in: .whitespaces),
            telephone: PhoneNumber.normalize(telephone),
            dateNaissance: SupabaseDate.day(from: dateNaissance),
            sexe: sexe.rawValue
        )

        let updated: [ProfileRow] = try await Supa.client
            .from("profiles")
            .update(payload)
            .eq("id", value: profileId.uuidString)
            .select(ProfileRow.allColumns)
            .execute()
            .value

        guard !updated.isEmpty else {
            throw SessionProfileError.updateRejected
        }
    }

    // MARK: - club_members

    private static func fetchClubMember(userId: UUID) async throws -> ClubMemberRow {
        let rows: [ClubMemberRow] = try await Supa.client
            .from("club_members")
            .select(ClubMemberRow.columns)
            .eq("profile_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let member = rows.first else {
            throw SessionProfileError.noClubMembership
        }
        return member
    }

    // MARK: - clubs (tolérant)

    private static func fetchClubName(clubId: UUID) async -> String? {
        for columns in ["id, nom", "id, name"] {
            do {
                let rows: [ClubRow] = try await Supa.client
                    .from("clubs")
                    .select(columns)
                    .eq("id", value: clubId.uuidString)
                    .limit(1)
                    .execute()
                    .value
                if let name = rows.first?.displayName { return name }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - memberships (tolérant)

    private static func fetchActiveMembership(clubMemberId: UUID) async -> MembershipRow? {
        do {
            let rows: [MembershipRow] = try await Supa.client
                .from("memberships")
                .select(MembershipRow.columns)
                .eq("club_member_id", value: clubMemberId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value

            // Le tri par `created_at` décroissant est fait côté serveur : on prend
            // ensuite la première ligne `a_jour`, jamais la première ligne trouvée.
            return rows.first(where: \.isActive)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func displayName(prenom: String?, nom: String, email: String) -> String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !full.isEmpty { return full }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}
