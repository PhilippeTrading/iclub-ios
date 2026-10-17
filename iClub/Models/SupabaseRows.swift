//
//  SupabaseRows.swift
//  iClub
//
//  DTO de lecture des tables Supabase. Les clés sont déclarées explicitement
//  (pas de conversion automatique snake_case) et les dates sont décodées en
//  `String` puis converties par `SupabaseDate` : Postgres renvoie selon la
//  colonne un `date` nu (`2026-05-12`) ou un `timestamptz`, et laisser
//  `JSONDecoder` arbitrer est une source d'échecs silencieux.
//

import Foundation

// MARK: - profiles

struct ProfileRow: Decodable, Sendable {
    let id: UUID
    let email: String?
    let nom: String?
    let prenom: String?
    let telephone: String?
    let dateNaissance: String?
    let sexe: String?
    let avatarUrl: String?
    let isPlatformAdmin: Bool?

    enum CodingKeys: String, CodingKey {
        case id, email, nom, prenom, sexe, telephone
        case dateNaissance = "date_naissance"
        case avatarUrl = "avatar_url"
        case isPlatformAdmin = "is_platform_admin"
    }

    /// Colonnes indispensables au chargement de session.
    static let coreColumns = "id, email, nom, prenom, avatar_url"

    /// Colonnes complètes, y compris celles susceptibles de dépendre d'une
    /// migration récente. En cas d'échec on retombe sur `coreColumns`.
    ///
    /// Les classements n'y figurent pas : ils vivent sur `club_members`, pas
    /// sur `profiles`. Les avoir listés ici faisait échouer *toute* la requête
    /// avec un `42703`, et le repli sur `coreColumns` perdait alors
    /// silencieusement téléphone, date de naissance et sexe à chaque lecture.
    static let allColumns =
        "id, email, nom, prenom, telephone, date_naissance, sexe, avatar_url, is_platform_admin"
}

/// Champs modifiables par le membre depuis son espace profil. Un utilisateur ne
/// peut mettre à jour que sa propre ligne : la restriction est portée par les
/// règles de sécurité, le filtre `id` ne fait que la refléter.
nonisolated struct ProfileUpdate: Encodable, Sendable {
    let prenom: String
    let nom: String
    let telephone: String
    let dateNaissance: String
    let sexe: String

    enum CodingKeys: String, CodingKey {
        case prenom, nom, telephone, sexe
        case dateNaissance = "date_naissance"
    }
}

/// Mise à jour de la seule photo de profil, séparée de `ProfileUpdate` : changer
/// sa photo ne doit pas réécrire prénom, nom, téléphone et date de naissance.
nonisolated struct AvatarUpdate: Encodable, Sendable {
    let avatarUrl: String

    enum CodingKeys: String, CodingKey {
        case avatarUrl = "avatar_url"
    }
}

// MARK: - club_members

struct ClubMemberRow: Decodable, Sendable {
    let id: UUID
    let clubId: UUID
    let profileId: UUID
    let role: String?
    let isAdmin: Bool?
    /// Les classements sont portés par l'appartenance au club, pas par le
    /// profil : ils sont propres au club et tenus par son secrétariat.
    let classementTennis: String?
    let classementPadel: Double?

    enum CodingKeys: String, CodingKey {
        case id, role
        case clubId = "club_id"
        case profileId = "profile_id"
        case isAdmin = "is_admin"
        case classementTennis = "classement_tennis"
        case classementPadel = "classement_padel"
    }

    static let columns =
        "id, club_id, profile_id, role, is_admin, classement_tennis, classement_padel"
}

// MARK: - memberships

struct MembershipRow: Decodable, Sendable {
    let statut: String?
    let dateDebut: String?
    let dateFin: String?
    let formule: String?
    let montant: Double?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case statut, formule, montant
        case dateDebut = "date_debut"
        case dateFin = "date_fin"
        case createdAt = "created_at"
    }

    static let columns = "statut, date_debut, date_fin, formule, montant, created_at"

    /// Statut d'une adhésion considérée comme active côté web.
    static let activeStatus = "a_jour"

    var isActive: Bool { statut == Self.activeStatus }
}

// MARK: - clubs

struct ClubRow: Decodable, Sendable {
    let id: UUID
    let nom: String?
    let name: String?

    var displayName: String? {
        if let nom, !nom.isEmpty { return nom }
        if let name, !name.isEmpty { return name }
        return nil
    }
}

// MARK: - Décodage tolérant par élément

/// Enveloppe permettant de décoder un tableau sans qu'une seule ligne
/// malformée fasse échouer l'ensemble. Utile sur les tables administrables
/// depuis le back-office, où une valeur inattendue est toujours possible.
nonisolated struct Lenient<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

extension Array {
    func compactValues<Wrapped>() -> [Wrapped] where Element == Lenient<Wrapped> {
        compactMap(\.value)
    }
}

// MARK: - Dates

/// Conversions date ↔︎ Postgres, centralisées pour éviter les divergences de
/// format entre écrans.
///
/// Les styles `Date.ISO8601FormatStyle` sont des valeurs `Sendable`, là où un
/// `DateFormatter` est une classe : cela permet à l'enum d'être `nonisolated`
/// et donc utilisable depuis les DTO, qui sont décodés hors de l'acteur principal.
nonisolated enum SupabaseDate {

    /// `date` Postgres : `2026-05-12`, interprétée dans le fuseau local.
    private static let dayStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        timeZone: .current
    )
    .year()
    .month()
    .day()

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Accepte indifféremment une `date` nue ou un `timestamptz`.
    ///
    /// Le format est reconnu par la *forme* de la chaîne, et non en essayant
    /// les analyseurs l'un après l'autre : l'analyseur jour-seul accepte un
    /// préfixe, si bien qu'un `timestamptz` lui serait décodé à minuit et
    /// perdrait son heure. C'est justement l'heure qui décide si un crédit
    /// invité est restitué.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        // Une colonne `date` s'écrit « 2026-05-12 » : aucun séparateur d'heure.
        let hasTime = value.contains("T") || value.contains(" ")
        guard hasTime else {
            return try? dayStyle.parse(value)
        }

        if let date = try? fractionalStyle.parse(value) { return date }
        if let date = try? timestampStyle.parse(value) { return date }
        // Postgres renvoie parfois `2026-05-12 10:00:00+00` (espace, pas de `T`).
        return try? timestampStyle.parse(value.replacingOccurrences(of: " ", with: "T"))
    }

    static func day(from date: Date) -> String {
        dayStyle.format(date)
    }

    /// Recombine une colonne `date` et une colonne `time` en un instant local :
    /// « 2026-09-23 » + « 14:00:00 » → le 23 septembre à 14 h, fuseau de
    /// l'appareil. Utilisé pour comparer une heure de début à un `timestamptz`.
    static func dateTime(day: String?, time: String?) -> Date? {
        guard let base = parse(day),
              let minutes = ClubSportSettingsRow.minutes(from: time)
        else { return nil }

        return Calendar.current.date(
            byAdding: .minute,
            value: minutes,
            to: Calendar.current.startOfDay(for: base)
        )
    }
}
