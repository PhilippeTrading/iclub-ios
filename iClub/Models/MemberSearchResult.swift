//
//  MemberSearchResult.swift
//  iClub
//
//  Résultat de la fonction `search_club_members`.
//
//  Un membre ne peut pas lire les fiches des autres membres : ces tables
//  portent e-mail, téléphone et date de naissance, et les règles de sécurité
//  l'interdisent. Cette fonction est le seul chemin autorisé : elle ne renvoie
//  volontairement pas l'e-mail, et il n'y a pas à chercher à l'obtenir autrement.
//
//  Rôle
//    Lignes et paramètres des deux fonctions SQL d'annuaire :
//    `search_club_members` (chercher un partenaire) et `get_club_roster_info`
//    (photo, âge et classements des participants d'une réservation).
//
//  Place dans l'application
//    `ClubDirectoryService` les appelle ; la recherche de partenaires
//    (`MemberSearchSheet`), la messagerie (nouveau message, fiche membre), les
//    parties ouvertes, le détail d'une réservation, l'accueil, les cours et
//    l'espace entraîneur affichent leurs résultats.
//
//  Droits et sécurité
//    Les deux fonctions sont `security definer` : elles lisent `profiles` et
//    `club_members` en contournant la RLS, mais ne rendent que des membres des
//    clubs de l'appelant (`current_club_ids()`), et jamais l'adresse, le
//    téléphone ni la date de naissance.
//

import Foundation

/// Ligne de `search_club_members` (ou partenaire récent reconstitué).
///
/// La fonction renvoie aussi `age`, `classement_tennis` et `classement_padel`,
/// qui ne sont pas décodés ici : les classements sont relus par
/// `get_club_roster_info`.
nonisolated struct MemberSearchResult: Decodable, Identifiable, Hashable, Sendable {
    /// `profile_id`.
    let profileId: UUID
    /// `nom`.
    let nom: String?
    /// `prenom`.
    let prenom: String?
    /// `avatar_url`.
    let avatarUrl: String?
    /// Faux pour un membre du club dont l'adhésion a expiré : il devra régler
    /// sa part comme un invité, ce qui est signalé dans la liste.
    /// (`has_active_membership` : une ligne `memberships` « a_jour » existe,
    /// sans contrôle de sa période.) Attention : dans l'app, seul le libellé
    /// change ; sa part n'est pas ajoutée au total à régler, alors que le web
    /// la facture.
    let hasActiveMembership: Bool

    /// Identifiant de liste : le profil.
    var id: UUID { profileId }

    /// Correspondance avec les colonnes renvoyées par la fonction.
    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case nom, prenom
        case avatarUrl = "avatar_url"
        case hasActiveMembership = "has_active_membership"
    }

    /// Prénom et nom, ou « Membre du club » si les deux sont vides.
    var displayName: String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Membre du club" : full
    }

    /// Initiales du prénom et du nom, « ? » à défaut.
    var initials: String {
        let value = (prenom?.first.map(String.init) ?? "") + (nom?.first.map(String.init) ?? "")
        return value.uppercased().isEmpty ? "?" : value.uppercased()
    }

    /// Nombre minimal de caractères avant d'interroger la fonction.
    /// (La fonction applique le même seuil : en deçà, elle ne rend rien.)
    static let minimumQueryLength = 2
}

/// Paramètres typés plutôt qu'un dictionnaire : `target_club_id` est un `uuid`
/// côté Postgres, l'encoder en `UUID` évite de dépendre d'un transtypage.
nonisolated struct MemberSearchParams: Encodable, Sendable {
    /// `target_club_id` : club où chercher.
    let targetClubId: UUID
    /// `q` : texte cherché dans le prénom ou le nom (sans tenir compte de la
    /// casse ; la fonction retire elle-même les espaces de bord).
    let q: String

    /// Noms des paramètres de la fonction SQL.
    enum CodingKeys: String, CodingKey {
        case targetClubId = "target_club_id"
        case q
    }
}

// MARK: - Classements

/// Résultat de `get_club_roster_info` : photo et classements des participants
/// d'une réservation. Même raison d'être que la recherche : la fiche d'un autre
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
    /// `profile_id`.
    let profileId: UUID
    /// `prenom`.
    let prenom: String?
    /// `nom`.
    let nom: String?
    /// `avatar_url`.
    let avatarUrl: String?
    /// `classement_tennis` du club.
    let classementTennis: String?
    /// `classement_padel` du club.
    let classementPadel: Double?
    /// `date_naissance`, absente de la version actuelle de la fonction.
    let dateNaissance: String?
    /// `age` : années révolues, calculées par la base.
    let ageFromServer: Int?

    /// Identifiant de liste : le profil.
    var id: UUID { profileId }

    /// Correspondance avec les colonnes renvoyées par la fonction.
    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case prenom, nom
        case avatarUrl = "avatar_url"
        case classementTennis = "classement_tennis"
        case classementPadel = "classement_padel"
        case dateNaissance = "date_naissance"
        case ageFromServer = "age"
    }

    /// Prénom et nom, ou « Membre du club » si les deux sont vides.
    var displayName: String {
        let full = [prenom, nom]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Membre du club" : full
    }

    /// Prénom seul, `nil` s'il est vide.
    var firstName: String? {
        guard let prenom, !prenom.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return prenom
    }

    /// Initiales du prénom et du nom, « ? » à défaut.
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

    /// Classement padel avec une décimale et une virgule (« 4,5 »), ou
    /// « Non renseigné ».
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

    /// « 34 ans », ou `nil` si l'âge est inconnu ou nul.
    var ageLabel: String? {
        guard let age, age > 0 else { return nil }
        return "\(age) ans"
    }

    /// Classement pertinent pour le sport de la réservation. Rien en
    /// pickleball : le club n'y tient pas de classement.
    ///
    /// - Parameter sport: sport de la réservation, `nil` s'il est inconnu.
    /// - Returns: le classement à afficher, ou `nil`.
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

/// Paramètre de `get_club_roster_info`.
nonisolated struct RosterInfoParams: Encodable, Sendable {
    /// `target_profile_ids` (`uuid[]`) : profils à décrire. La fonction ne rend
    /// que ceux qui sont membres d'un club de l'appelant.
    let targetProfileIds: [UUID]

    /// Nom du paramètre de la fonction SQL.
    enum CodingKeys: String, CodingKey {
        case targetProfileIds = "target_profile_ids"
    }
}
