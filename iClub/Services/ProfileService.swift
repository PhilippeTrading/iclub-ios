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
//     `statut = 'a_jour'` : un membre a plusieurs lignes historiques.
//  2. Aucun champ optionnel ou récent ne doit bloquer le chargement de session :
//     nom du club et adhésion sont chargés par des appels séparés tolérants à
//     l'échec, et la lecture de `profiles` retombe sur un jeu de colonnes
//     minimal si une colonne manque.
//
//  Place dans l'application
//    `AuthController` (chargement et rafraîchissement de la session),
//    `ProfileCompletionView` et `PersonalInfoSection` (informations
//    personnelles), `RankingsSection` (classements).
//
//  Tables et fonctions SQL
//    - Lecture : `profiles` (sa ligne), `club_members` (sa ligne), `clubs`
//      (lecture publique), `memberships` (ses adhésions). Les règles RLS
//      limitent chaque lecture à ce qui concerne le membre connecté.
//    - Écriture : `profiles` (RLS `profiles_update_self`) ;
//      `update_my_tennis_ranking(new_classement)` et
//      `update_my_padel_ranking(new_classement)` (migration
//      `20260925100000_classement_padel_membre.sql`), seules portes d'écriture
//      sur `club_members` pour un membre.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet). Les lectures de la
//    session se font l'une après l'autre (profil, appartenance, club,
//    adhésion). Aucun cache : `AuthController` garde le résultat.
//

import Foundation
import Supabase

/// Erreur d'enregistrement d'un classement.
enum RankingError: LocalizedError {
    /// Refus de la base, déjà rédigé : « Classement tennis invalide ».
    case rejected(String)

    /// Message de la base, affiché tel quel.
    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}

/// Erreurs du chargement et de l'édition du profil de session.
enum SessionProfileError: LocalizedError {
    /// Le compte n'a aucune ligne `club_members` : `AuthController` tente
    /// alors le rattachement automatique.
    case noClubMembership
    /// Profil introuvable ou illisible. (Déclarée, mais levée nulle part dans
    /// l'app à ce jour.)
    case profileUnavailable
    /// L'écriture n'a touché aucune ligne : refusée par les règles de sécurité,
    /// ou profil introuvable.
    case updateRejected

    /// Message affiché (écran de blocage ou formulaire).
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
    /// `new_classement` : texte (tennis) ou nombre (padel), `nil` pour effacer.
    let newClassement: Value?

    /// Nom du paramètre SQL.
    enum CodingKeys: String, CodingKey {
        case newClassement = "new_classement"
    }

    /// Écrit la valeur, ou `null` explicitement.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let newClassement {
            try container.encode(newClassement, forKey: .newClassement)
        } else {
            try container.encodeNil(forKey: .newClassement)
        }
    }
}

/// Profil de session et informations personnelles du membre.
enum ProfileService {

    // MARK: - Classements

    /// Les classements vivent sur `club_members`, que le membre n'a pas le
    /// droit de modifier directement : c'est ce qui l'empêche de se nommer
    /// administrateur. Ces deux fonctions ouvrent exactement la porte
    /// nécessaire, et valident la valeur reçue côté base.
    ///
    /// La fonction met à jour toutes les lignes `club_members` du membre
    /// (chacun de ses clubs).
    ///
    /// - Parameter value: `nil` pour effacer le classement.
    /// - Throws: `RankingError.rejected` pour une valeur hors échelle, ou
    ///   l'erreur brute de l'appel.
    static func updateTennisRanking(_ value: String?) async throws {
        try await callRanking("update_my_tennis_ranking", RankingParam(newClassement: value))
    }

    /// Même principe pour le padel : valeur de 1,0 à 10,0 par pas de 0,5,
    /// vérifiée par la base.
    ///
    /// - Parameter value: `nil` pour effacer le classement.
    /// - Throws: `RankingError.rejected` pour une valeur hors échelle, ou
    ///   l'erreur brute de l'appel.
    static func updatePadelRanking(_ value: Double?) async throws {
        try await callRanking("update_my_padel_ranking", RankingParam(newClassement: value))
    }

    /// Appel commun aux deux fonctions de classement.
    ///
    /// - Parameters:
    ///   - function: nom de la fonction SQL.
    ///   - params: paramètre `new_classement`.
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

    /// Construit le profil de session du membre connecté.
    ///
    /// - Parameters:
    ///   - userId: identifiant de l'utilisateur Supabase Auth (= `profiles.id`).
    ///   - email: adresse de la session, utilisée si `profiles.email` est vide.
    /// - Returns: le profil agrégé.
    /// - Throws: `SessionProfileError.noClubMembership` sans appartenance ;
    ///   l'erreur de la requête si `profiles` ou `club_members` ne répondent pas.
    static func loadSessionProfile(userId: UUID, email: String) async throws -> SessionProfile {
        // Bloquants : sans profil ni appartenance, pas de session exploitable.
        let profile = try await fetchProfile(userId: userId)
        let member = try await fetchClubMember(userId: userId)

        // Non bloquants : un échec ici ne doit jamais empêcher la connexion.
        let clubName = await fetchClubName(clubId: member.clubId)
        let membership = await fetchActiveMembership(clubMemberId: member.id)

        let nom = profile.nom ?? ""
        let prenom = profile.prenom
        let resolvedEmail = profile.email ?? email

        // Période de l'adhésion active, seulement si les deux dates se lisent.
        let period: (debut: Date, fin: Date)? = {
            guard let membership,
                  let debut = SupabaseDate.parse(membership.dateDebut),
                  let fin = SupabaseDate.parse(membership.dateFin)
            else { return nil }
            return (debut, fin)
        }()

        // Formule et montant (0 € si le montant est vide).
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
            // Droit d'encadrer, ou ancien rôle d'affichage « entraineur ».
            isCoach: member.estEntraineur == true || member.role == "entraineur",
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

    /// Ligne `profiles` du membre.
    ///
    /// - Parameter userId: identifiant du profil.
    /// - Returns: la ligne, avec toutes les colonnes si possible.
    /// - Throws: l'erreur de la seconde lecture si les deux échouent (`.single()`
    ///   échoue aussi quand la ligne n'existe pas).
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
    /// lorsque *aucune* ligne n'a été touchée : une écriture refusée par les
    /// règles de sécurité serait indiscernable d'un succès, et l'écran
    /// annoncerait un enregistrement qui n'a pas eu lieu.
    ///
    /// - Parameters:
    ///   - profileId: profil du membre connecté (la RLS refuse tout autre).
    ///   - prenom: prénom (espaces de bord retirés).
    ///   - nom: nom (espaces de bord retirés).
    ///   - telephone: numéro saisi.
    ///   - dateNaissance: date de naissance (écrite « AAAA-MM-JJ »).
    ///   - sexe: sexe (« H » ou « F »).
    /// - Throws: `AuthServiceError.invalidPhone`,
    ///   `SessionProfileError.updateRejected`, ou l'erreur de la requête.
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

    /// Appartenance du membre à un club.
    ///
    /// Limite connue : sans tri, un membre de plusieurs clubs obtient l'une de
    /// ses appartenances, sans ordre garanti. L'app est mono-club.
    ///
    /// - Parameter userId: profil du membre.
    /// - Returns: sa ligne `club_members`.
    /// - Throws: `SessionProfileError.noClubMembership` si aucune ligne, ou
    ///   l'erreur de la requête.
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

    /// Nom du club. Essaie la colonne `nom`, puis `name` (schéma d'une autre
    /// version) ; toute erreur passe à l'essai suivant.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: le nom, ou `nil` si aucun essai n'aboutit.
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

    /// Adhésion active du membre.
    ///
    /// - Parameter clubMemberId: appartenance du membre.
    /// - Returns: la plus récente des lignes « à jour » dont la période couvre
    ///   aujourd'hui, ou `nil` (aucune, ou erreur de lecture).
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
            // ensuite la première ligne `a_jour` dont la période couvre
            // aujourd'hui, comme le web, jamais la première ligne trouvée.
            // Bornes incluses, jour de l'appareil ; une date illisible ne
            // restreint pas la période.
            let today = Calendar.current.startOfDay(for: .now)
            return rows.first { row in
                guard row.isActive else { return false }
                let starts = SupabaseDate.parse(row.dateDebut).map { $0 <= today } ?? true
                let ends = SupabaseDate.parse(row.dateFin).map { $0 >= today } ?? true
                return starts && ends
            }
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Nom affiché : prénom et nom, sinon la partie de l'adresse avant « @ ».
    ///
    /// - Parameters:
    ///   - prenom: prénom, éventuellement absent.
    ///   - nom: nom, éventuellement vide.
    ///   - email: adresse de repli.
    /// - Returns: le nom à afficher.
    private static func displayName(prenom: String?, nom: String, email: String) -> String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !full.isEmpty { return full }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}
