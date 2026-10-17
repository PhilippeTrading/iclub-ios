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

import Foundation

/// Qui règle la part d'un invité.
nonisolated enum GuestPayer: Hashable, Sendable {
    /// Gratuit, consomme un crédit invité du réservataire.
    case credit
    /// Ajoute le supplément au total à régler.
    case supplement
}

nonisolated struct BookingParticipant: Identifiable, Hashable, Sendable {

    nonisolated enum Kind: Hashable, Sendable {
        /// L'utilisateur connecté : toujours premier, jamais supprimable.
        case owner
        case member
        case guest(payer: GuestPayer)

        /// Valeur écrite dans `reservation_participants.type`.
        var storedType: String {
            switch self {
            case .owner, .member: "membre"
            case .guest: "invite"
            }
        }
    }

    /// Identité locale : un invité n'a pas de `profileId` pour le distinguer.
    let id: UUID
    /// `nil` pour un invité non-membre.
    let profileId: UUID?
    let prenom: String
    let nom: String
    let avatarUrl: URL?
    var kind: Kind
    /// Faux pour un membre du club dont l'adhésion a expiré — cas réel, signalé
    /// discrètement dans la liste.
    let hasActiveMembership: Bool

    var displayName: String {
        let full = [prenom, nom]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? "Participant" : full
    }

    var initials: String {
        let value = (prenom.first.map(String.init) ?? "") + (nom.first.map(String.init) ?? "")
        return value.uppercased().isEmpty ? "?" : value.uppercased()
    }

    var isRemovable: Bool { kind != .owner }

    var usesCredit: Bool { kind == .guest(payer: .credit) }

    /// Supplément porté par ce participant. Seul un invité au supplément en a :
    /// le total à régler est la somme de ces lignes.
    var supplement: Double {
        kind == .guest(payer: .supplement) ? BookingPricing.guestSupplement : 0
    }

    var roleLabel: String {
        switch kind {
        case .owner: "Réservataire"
        case .member: hasActiveMembership ? "Adhérent" : "Sans adhésion active"
        case .guest(.credit): "Invité · crédit"
        case .guest(.supplement): "Invité · supplément"
        }
    }

    // MARK: - Fabriques

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
