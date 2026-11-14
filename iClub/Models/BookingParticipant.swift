//
//  BookingParticipant.swift
//  iClub
//
//  Participants en cours de composition dans le tunnel, avant écriture.
//
//  Le `profileId` d'un membre est conservé jusqu'au bout : c'est lui qui est
//  écrit dans `reservation_participants.profile_id`, et c'est ce qui permet
//  ensuite d'afficher sa photo et son classement, de reconnaître « ma
//  réservation », et de faire apparaître la partie chez lui aussi. Un
//  participant enregistré sans identifiant serait invisible de son propre côté.
//
//  Place dans l'application
//    Composés par l'écran des joueurs (`ParticipantsView`, `MemberSearchSheet`,
//    `GuestFormSheet`) dans le brouillon `BookingDraft`, puis convertis en
//    `ReservationParticipantInsert` par `ReservationService.confirm`.
//
//  Règles métier
//    - Le réservataire est toujours le premier joueur, et ne peut pas être retiré.
//    - Un invité est gratuit s'il consomme un crédit invité du réservataire,
//      sinon il ajoute le supplément invité (`BookingPricing.guestSupplement`)
//      au total à régler.
//    - Un membre, même sans adhésion active, n'ajoute rien au total dans l'app.
//      Attention : le web lui fait payer sa part du créneau (voir
//      PriceFormatting.swift).
//

import Foundation

/// Qui règle la part d'un invité.
nonisolated enum GuestPayer: Hashable, Sendable {
    /// Gratuit, consomme un crédit invité du réservataire.
    case credit
    /// Ajoute le supplément au total à régler.
    case supplement
}

/// Un joueur ajouté à la réservation en cours de composition.
nonisolated struct BookingParticipant: Identifiable, Hashable, Sendable {

    /// Nature du joueur, qui décide de son type en base et de ce qu'il coûte.
    nonisolated enum Kind: Hashable, Sendable {
        /// L'utilisateur connecté : toujours premier, jamais supprimable.
        case owner
        /// Un autre membre du club, trouvé par la recherche.
        case member
        /// Un invité extérieur, saisi à la main, avec qui paie sa part.
        case guest(payer: GuestPayer)

        /// Valeur écrite dans `reservation_participants.type`.
        /// (`membre` ou `invite`, contrainte `check` de la colonne.)
        var storedType: String {
            switch self {
            case .owner, .member: "membre"
            case .guest: "invite"
            }
        }
    }

    /// Identité locale : un invité n'a pas de `profileId` pour le distinguer.
    /// Pour un membre, c'est son identifiant de profil ; pour un invité, un
    /// identifiant tiré au hasard.
    let id: UUID
    /// `nil` pour un invité non-membre.
    let profileId: UUID?
    /// Prénom (chaîne vide si inconnu).
    let prenom: String
    /// Nom (chaîne vide si inconnu).
    let nom: String
    /// Photo du membre, `nil` pour un invité ou un membre sans photo.
    let avatarUrl: URL?
    /// Nature du joueur. Déclarée modifiable (`var`), mais aucun écran ne la
    /// change à ce jour.
    var kind: Kind
    /// Faux pour un membre du club dont l'adhésion a expiré : cas réel, signalé
    /// discrètement dans la liste.
    let hasActiveMembership: Bool

    /// Prénom et nom, ou « Participant » si les deux sont vides. C'est la
    /// valeur écrite dans `reservation_participants.nom_affiche`.
    var displayName: String {
        let full = [prenom, nom]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Participant" : full
    }

    /// Initiales du prénom et du nom, « ? » à défaut.
    var initials: String {
        let value = (prenom.first.map(String.init) ?? "") + (nom.first.map(String.init) ?? "")
        return value.uppercased().isEmpty ? "?" : value.uppercased()
    }

    /// Tout joueur sauf le réservataire peut être retiré.
    var isRemovable: Bool { kind != .owner }

    /// Invité dont la place est prise sur un crédit (`used_credit`).
    var usesCredit: Bool { kind == .guest(payer: .credit) }

    /// Supplément porté par ce participant. Seul un invité au supplément en a :
    /// le total à régler est la somme de ces lignes.
    /// En euros (`reservation_participants.supplement`).
    var supplement: Double {
        kind == .guest(payer: .supplement) ? BookingPricing.guestSupplement : 0
    }

    /// Rôle affiché sous le nom dans la liste des joueurs.
    var roleLabel: String {
        switch kind {
        case .owner: "Réservataire"
        case .member: hasActiveMembership ? "Adhérent" : "Sans adhésion active"
        case .guest(.credit): "Invité · crédit"
        case .guest(.supplement): "Invité · supplément"
        }
    }

    // MARK: - Fabriques

    /// Le réservataire, à partir du profil au nom de qui l'on réserve.
    ///
    /// - Parameter profile: profil actif (le compte connecté, ou l'enfant).
    /// - Returns: un participant de type `owner`.
    static func owner(_ profile: SessionProfile) -> BookingParticipant {
        BookingParticipant(
            id: profile.id,
            profileId: profile.id,
            prenom: profile.prenom ?? "",
            nom: profile.nom,
            avatarUrl: profile.avatarUrl,
            kind: .owner,
            hasActiveMembership: profile.hasActiveMembership
        )
    }

    /// Un membre trouvé par la recherche ou parmi les partenaires récents.
    ///
    /// - Parameter result: ligne de `search_club_members`, ou partenaire
    ///   récent reconstitué par `ClubDirectoryService`. Pour ce dernier,
    ///   `hasActiveMembership` est souvent faux à tort (voir
    ///   `ClubDirectoryService.profilesWithActiveMembership`).
    /// - Returns: un participant de type `member`.
    static func member(_ result: MemberSearchResult) -> BookingParticipant {
        BookingParticipant(
            id: result.profileId,
            profileId: result.profileId,
            prenom: result.prenom ?? "",
            nom: result.nom ?? "",
            avatarUrl: result.avatarUrl.flatMap(URL.init(string:)),
            kind: .member,
            hasActiveMembership: result.hasActiveMembership
        )
    }

    /// Un invité saisi à la main.
    ///
    /// - Parameters:
    ///   - prenom: prénom saisi (espaces de bord retirés).
    ///   - nom: nom saisi (espaces de bord retirés).
    ///   - payer: crédit ou supplément.
    /// - Returns: un participant de type `guest`, sans profil.
    static func guest(prenom: String, nom: String, payer: GuestPayer) -> BookingParticipant {
        BookingParticipant(
            id: UUID(),
            profileId: nil,
            prenom: prenom.trimmingCharacters(in: .whitespaces),
            nom: nom.trimmingCharacters(in: .whitespaces),
            avatarUrl: nil,
            kind: .guest(payer: payer),
            hasActiveMembership: false
        )
    }
}
