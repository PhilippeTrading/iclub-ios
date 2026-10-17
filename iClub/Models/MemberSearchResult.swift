//
//  MemberSearchResult.swift
//  iClub
//
//  Résultat de la fonction `search_club_members`.
//
//  Un membre ne peut pas lire les fiches des autres membres : ces tables
//  portent e-mail, téléphone et date de naissance, et les règles de sécurité
//  l'interdisent. Cette fonction est le seul chemin autorisé — elle ne renvoie
//  volontairement pas l'e-mail, et il n'y a pas à chercher à l'obtenir autrement.
//

import Foundation

nonisolated struct MemberSearchResult: Decodable, Identifiable, Hashable, Sendable {
    let profileId: UUID
    let nom: String?
    let prenom: String?
    let avatarUrl: String?
    /// Faux pour un membre du club dont l'adhésion a expiré : il devra régler
    /// sa part comme un invité, ce qui est signalé dans la liste.
    let hasActiveMembership: Bool

    var id: UUID { profileId }

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case nom, prenom
        case avatarUrl = "avatar_url"
        case hasActiveMembership = "has_active_membership"
    }

    var displayName: String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Membre du club" : full
    }

    var initials: String {
        let value = (prenom?.first.map(String.init) ?? "") + (nom?.first.map(String.init) ?? "")
        return value.uppercased().isEmpty ? "?" : value.uppercased()
    }

    /// Nombre minimal de caractères avant d'interroger la fonction.
    static let minimumQueryLength = 2
}

/// Paramètres typés plutôt qu'un dictionnaire : `target_club_id` est un `uuid`
/// côté Postgres, l'encoder en `UUID` évite de dépendre d'un transtypage.
nonisolated struct MemberSearchParams: Encodable, Sendable {
    let targetClubId: UUID
    let q: String

    enum CodingKeys: String, CodingKey {
        case targetClubId = "target_club_id"
        case q
    }
}

// MARK: - Classements

/// Résultat de `get_club_roster_info` : photo et classements des participants
/// d'une réservation. Même raison d'être que la recherche — la fiche d'un autre
/// membre n'est pas lisible directement.
/// Forme renvoyée par `get_club_roster_info` :
/// `profile_id, prenom, nom, avatar_url, age, classement_tennis, classement_padel`.
///
/// L'âge est **calculé côté base** à partir de la date de naissance, qui n'est
/// jamais exposée. Il ne doit pas être mis en cache : il serait faux dès le
/// lendemain d'un anniversaire.
///
/// `dateNaissance` reste décodée par tolérance, si la fonction venait à
/// renvoyer la date brute à la place de l'âge.
nonisolated struct RosterInfoRow: Decodable, Identifiable, Sendable {
    let profileId: UUID
    let prenom: String?
    let nom: String?
    let avatarUrl: String?
    let classementTennis: String?
    let classementPadel: Double?
    let dateNaissance: String?
    let ageFromServer: Int?

    var id: UUID { profileId }

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case prenom, nom
        case avatarUrl = "avatar_url"
        case classementTennis = "classement_tennis"
        case classementPadel = "classement_padel"
        case dateNaissance = "date_naissance"
        case ageFromServer = "age"
    }

    var displayName: String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Membre du club" : full
    }

    var firstName: String? {
        guard let prenom, !prenom.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return prenom
    }

    var initials: String {
        let value = (prenom?.first.map(String.init) ?? "") + (nom?.first.map(String.init) ?? "")
        return value.uppercased().isEmpty ? "?" : value.uppercased()
    }

    /// Classement affiché tel quel dans la fiche joueur, virgule française pour
    /// le padel. « Non renseigné » plutôt qu'un vide.
    var tennisLabel: String {
        guard let classementTennis, !classementTennis.isEmpty else { return "Non renseigné" }
        return classementTennis
    }

    var padelLabel: String {
        guard let classementPadel else { return "Non renseigné" }
        return Ranking.display(Ranking.stored(padel: classementPadel), sport: .padel)
    }

    /// Âge en années révolues, quelle que soit la forme renvoyée par la base.
    var age: Int? {
        if let ageFromServer { return ageFromServer }
        guard let birth = SupabaseDate.parse(dateNaissance) else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: .now).year
    }

    var ageLabel: String? {
        guard let age, age > 0 else { return nil }
        return "\(age) ans"
    }

    /// Classement pertinent pour le sport de la réservation. Rien en
    /// pickleball : le club n'y tient pas de classement.
    func ranking(for sport: Sport?) -> String? {
        switch sport {
        case .tennis:
            guard let classementTennis, !classementTennis.isEmpty else { return nil }
            return classementTennis
        case .padel:
            guard let classementPadel else { return nil }
            // Passe par `Ranking` plutôt que de formater ici : l'échelle padel
            // va par pas de 0,5 et s'écrit toujours avec une décimale. Une
            // précision variable affichait « 4 » à côté de « 4,5 ».
            return Ranking.display(Ranking.stored(padel: classementPadel), sport: .padel)
        case .pickleball, nil:
            return nil
        }
    }
}

nonisolated struct RosterInfoParams: Encodable, Sendable {
    let targetProfileIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case targetProfileIds = "target_profile_ids"
    }
}
