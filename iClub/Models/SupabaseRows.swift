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
//  Rôle
//    Lignes des tables lues au chargement de la session (`profiles`,
//    `club_members`, `memberships`, `clubs`), charges utiles de mise à jour du
//    profil, enveloppe de décodage tolérant `Lenient` et conversions de dates
//    `SupabaseDate`, utilisées par toute la couche Services/.
//
//  Place dans l'application
//    `ProfileService` (session, édition du profil), `AvatarService` (photo),
//    `AuthService` (nom transmis par Apple, photo Google), `ClubDirectoryService`
//    (statut d'adhésion `a_jour`) ; `Lenient` et `SupabaseDate` sont employés
//    par presque tous les services et modèles.
//
//  Droits et sécurité (RLS des tables lues ici)
//    - `profiles` : chacun lit et modifie sa propre ligne ; l'administration
//      du club lit celles de ses membres.
//    - `club_members` et `memberships` : chacun lit les siennes ;
//      l'administration du club lit tout et seule écrit.
//    - `clubs` : lecture publique.
//
//  Fil d'exécution
//    Les types marqués `nonisolated` se décodent hors de l'acteur principal.
//    `ProfileRow`, `ClubMemberRow`, `MembershipRow` et `ClubRow` ne le sont pas :
//    ils suivent l'isolement par défaut du projet (acteur principal).
//

import Foundation

// MARK: - profiles

/// Ligne de `profiles` : identité du membre. `id` est aussi l'identifiant de
/// l'utilisateur Supabase Auth (`auth.users.id`).
struct ProfileRow: Decodable, Sendable {
    /// `id` (= `auth.users.id`).
    let id: UUID
    /// `email` : adresse du compte. Nulle pour un compte d'enfant géré, qui n'a
    /// pas de connexion propre.
    let email: String?
    /// `nom`.
    let nom: String?
    /// `prenom`.
    let prenom: String?
    /// `telephone`, normalisé (chiffres, `+` en tête) ; `nil` pour les comptes
    /// anciens.
    let telephone: String?
    /// `date_naissance` (`date`), en texte « AAAA-MM-JJ ».
    let dateNaissance: String?
    /// `sexe` : « H » ou « F » (contrainte `check` de la colonne).
    let sexe: String?
    /// `avatar_url` : URL publique de la photo, suffixée de `?v=…` (voir
    /// `AvatarService`).
    let avatarUrl: String?
    /// `is_platform_admin` : administrateur de la plateforme iClub. Décodé mais
    /// inutilisé par l'app.
    let isPlatformAdmin: Bool?

    /// Correspondance avec les colonnes SQL.
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
/// (Politique RLS `profiles_update_self`.)
nonisolated struct ProfileUpdate: Encodable, Sendable {
    /// `prenom`, sans espaces de bord.
    let prenom: String
    /// `nom`, sans espaces de bord.
    let nom: String
    /// `telephone`, déjà normalisé par `PhoneNumber.normalize`.
    let telephone: String
    /// `date_naissance`, au format « AAAA-MM-JJ ».
    let dateNaissance: String
    /// `sexe` : « H » ou « F ».
    let sexe: String

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case prenom, nom, telephone, sexe
        case dateNaissance = "date_naissance"
    }
}

/// Mise à jour de la seule photo de profil, séparée de `ProfileUpdate` : changer
/// sa photo ne doit pas réécrire prénom, nom, téléphone et date de naissance.
nonisolated struct AvatarUpdate: Encodable, Sendable {
    /// Nouvelle valeur de `avatar_url` (URL complète).
    let avatarUrl: String

    /// Correspondance avec la colonne SQL.
    enum CodingKeys: String, CodingKey {
        case avatarUrl = "avatar_url"
    }
}

// MARK: - club_members

/// Ligne de `club_members` : appartenance d'un profil à un club, avec son rôle
/// et ses droits.
struct ClubMemberRow: Decodable, Sendable {
    /// `id` : identifiant de l'appartenance (référencé par `memberships` et
    /// `guest_credit_allowances`).
    let id: UUID
    /// `club_id`.
    let clubId: UUID
    /// `profile_id`.
    let profileId: UUID
    /// `role` : rôle d'affichage (`adherent`, `visiteur`, `invite`, `parent`,
    /// `junior`, `entraineur`, `secretaire`, `club_admin`).
    let role: String?
    /// `is_admin` : administrateur du club (back-office web).
    let isAdmin: Bool?
    /// Les classements sont portés par l'appartenance au club, pas par le
    /// profil : ils sont propres au club et tenus par son secrétariat.
    /// `classement_tennis` : valeur de l'échelle FFT (« 30/2 », « NC »…).
    let classementTennis: String?
    /// `classement_padel` (`numeric(3, 1)`, de 1,0 à 10,0).
    let classementPadel: Double?
    /// Droit d'encadrer des cours, accordé par un administrateur.
    /// (`est_entraineur`.)
    let estEntraineur: Bool?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, role
        case clubId = "club_id"
        case profileId = "profile_id"
        case isAdmin = "is_admin"
        case estEntraineur = "est_entraineur"
        case classementTennis = "classement_tennis"
        case classementPadel = "classement_padel"
    }

    /// Colonnes demandées.
    static let columns =
        "id, club_id, profile_id, role, is_admin, classement_tennis, classement_padel, est_entraineur"
}

// MARK: - memberships

/// Ligne de `memberships` : une adhésion (cotisation) d'un membre pour une
/// période. Un membre a plusieurs lignes au fil des saisons.
struct MembershipRow: Decodable, Sendable {
    /// `statut` : `a_jour`, `a_renouveler` ou `expiree`.
    let statut: String?
    /// `date_debut` (`date`), en texte.
    let dateDebut: String?
    /// `date_fin` (`date`), en texte.
    let dateFin: String?
    /// `formule` : nom de la formule choisie (texte recopié, pas une clé).
    let formule: String?
    /// `montant` (`numeric(8, 2)`, euros).
    let montant: Double?
    /// `created_at` (`timestamptz`), en texte.
    let createdAt: String?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case statut, formule, montant
        case dateDebut = "date_debut"
        case dateFin = "date_fin"
        case createdAt = "created_at"
    }

    /// Colonnes demandées.
    static let columns = "statut, date_debut, date_fin, formule, montant, created_at"

    /// Statut d'une adhésion considérée comme active côté web.
    static let activeStatus = "a_jour"

    /// `true` si l'adhésion est « à jour ». La période n'est pas vérifiée ici
    /// (voir `ProfileService.fetchActiveMembership`).
    var isActive: Bool { statut == Self.activeStatus }
}

// MARK: - clubs

/// Ligne de `clubs` réduite au nom.
///
/// La table nomme la colonne `nom` ; `name` est lu en repli, pour un schéma qui
/// aurait gardé un nom anglais. Décodage synthétisé : les clés sont les noms
/// des propriétés.
struct ClubRow: Decodable, Sendable {
    /// `id`.
    let id: UUID
    /// `nom`.
    let nom: String?
    /// `name` (repli, absent du schéma actuel).
    let name: String?

    /// Premier nom non vide, ou `nil`.
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
///
/// Usage : décoder `[Lenient<T>]`, puis `compactValues()` pour ne garder que
/// les lignes lisibles. Une ligne illisible disparaît sans bruit.
nonisolated struct Lenient<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    /// La ligne décodée, ou `nil` si son décodage a échoué.
    let value: Wrapped?

    /// Ne lève jamais : l'erreur de la ligne est avalée.
    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// Extraction des lignes lisibles d'un tableau décodé avec `Lenient`.
extension Array {
    /// Lignes décodées avec succès, dans l'ordre d'origine.
    ///
    /// - Returns: les valeurs non nulles d'un tableau de `Lenient`.
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
    /// (Fuseau de l'appareil : un jour lu ou écrit est le jour local.)
    private static let dayStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        timeZone: .current
    )
    .year()
    .month()
    .day()

    /// `timestamptz` sans fractions de seconde (« 2026-05-12T10:00:00+00:00 »).
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    /// `timestamptz` avec fractions de seconde, forme habituelle de PostgREST.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Accepte indifféremment une `date` nue ou un `timestamptz`.
    ///
    /// Le format est reconnu par la *forme* de la chaîne, et non en essayant
    /// les analyseurs l'un après l'autre : l'analyseur jour-seul accepte un
    /// préfixe, si bien qu'un `timestamptz` lui serait décodé à minuit et
    /// perdrait son heure. C'est justement l'heure qui décide si un crédit
    /// invité est restitué.
    ///
    /// - Parameter value: texte renvoyé par PostgREST, ou `nil`.
    /// - Returns: l'instant correspondant (minuit local pour une `date`), ou
    ///   `nil` si la valeur est absente, vide ou illisible.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        // Une colonne `date` s'écrit « 2026-05-12 » : aucun séparateur d'heure.
        let hasTime = value.contains("T") || value.contains(" ")
        guard hasTime else {
            return try? dayStyle.parse(value)
        }

        // Avec fractions d'abord (forme la plus fréquente), puis sans.
        if let date = try? fractionalStyle.parse(value) { return date }
        if let date = try? timestampStyle.parse(value) { return date }
        // Postgres renvoie parfois `2026-05-12 10:00:00+00` (espace, pas de `T`).
        return try? timestampStyle.parse(value.replacingOccurrences(of: " ", with: "T"))
    }

    /// Jour d'une date, au format d'une colonne `date` (« 2026-05-12 »), dans
    /// le fuseau de l'appareil. Sert aux filtres `.eq("date", …)` et aux
    /// écritures.
    ///
    /// - Parameter date: instant quelconque du jour voulu.
    /// - Returns: « AAAA-MM-JJ ».
    static func day(from date: Date) -> String {
        dayStyle.format(date)
    }

    /// Recombine une colonne `date` et une colonne `time` en un instant local :
    /// « 2026-09-23 » + « 14:00:00 » → le 23 septembre à 14 h, fuseau de
    /// l'appareil. Utilisé pour comparer une heure de début à un `timestamptz`.
    ///
    /// - Parameters:
    ///   - day: valeur de la colonne `date`.
    ///   - time: valeur de la colonne `time`.
    /// - Returns: l'instant, ou `nil` si l'une des deux valeurs est illisible.
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
