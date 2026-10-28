//
//  SessionProfile.swift
//  iClub
//
//  Équivalent Swift du `getSessionProfile()` server-side du web : agrège
//  `profiles`, `club_members`, le club et l'adhésion active en un seul objet
//  calculé une fois après connexion, puis rafraîchi après toute mutation
//  pertinente (édition de profil, annulation de réservation…).
//

import Foundation

struct SessionProfile: Sendable {
    let id: UUID                       // profiles.id (= auth.users.id)
    let clubMemberId: UUID
    let email: String
    let nom: String
    let prenom: String?
    let displayName: String
    let avatarUrl: URL?
    /// Numéro normalisé tel qu'il est en base. `nil` pour les comptes créés
    /// avant l'ajout de ce champ : l'app ne suppose jamais qu'un numéro existe.
    let telephone: String?
    let dateNaissance: Date?
    let sexe: Sexe?
    let role: String
    let isAdmin: Bool
    /// Entraîneur du club : `club_members.est_entraineur`, ou l'ancien rôle
    /// « entraineur ». La base vérifie tout ; l'app ne fait que montrer ou
    /// cacher l'espace entraîneur.
    var isCoach: Bool = false
    let clubId: UUID
    let clubName: String
    let classementTennis: String?
    let classementPadel: Double?
    let hasActiveMembership: Bool
    let activeMembershipPeriod: (debut: Date, fin: Date)?
    let activeMembershipDetails: (formule: String, montant: Double)?

    /// Initiales utilisées comme repli quand il n'y a pas de photo de profil.
    var initials: String {
        let first = prenom?.first.map(String.init) ?? ""
        let last = nom.first.map(String.init) ?? ""
        let value = (first + last).uppercased()
        return value.isEmpty ? "?" : value
    }

    /// Téléphone, date de naissance et sexe sont indispensables au
    /// fonctionnement du club : l'âge s'affiche sous chaque joueur, et le sexe
    /// conditionne la mixité des parties ouvertes.
    ///
    /// Google et Apple ne fournissent aucun des trois. Un profil incomplet
    /// mène donc à l'écran de complétion, **à chaque lancement** tant qu'il
    /// n'est pas complété — pas seulement à la création du compte.
    var isComplete: Bool {
        let hasPhone = telephone.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        return hasPhone && dateNaissance != nil && sexe != nil
    }

    /// « 06 12 34 56 78 », ou `nil` si aucun numéro n'est enregistré.
    var formattedTelephone: String? {
        PhoneNumber.formattedForDisplay(telephone)
    }

    /// Prénom pour l'accueil, avec repli sur le nom puis sur l'email.
    var greetingName: String {
        if let prenom, !prenom.isEmpty { return prenom }
        if !nom.isEmpty { return nom }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}

extension SessionProfile {
    /// Le profil d'un enfant vu comme un profil de session, pour que les
    /// onglets lisent et proposent les choses à son nom.
    ///
    /// Ce que la base ne laisse pas lire au parent reste prudent : la date de
    /// naissance est reconstituée depuis l'âge, et l'adhésion de l'enfant est
    /// tenue pour inconnue (donc non active).
    static func child(_ child: ManagedProfile, of parent: SessionProfile) -> SessionProfile {
        let birth = child.age.flatMap { Calendar.current.date(byAdding: .year, value: -$0, to: .now) }
        return SessionProfile(
            id: child.profileId,
            clubMemberId: child.clubMemberId ?? parent.clubMemberId,
            email: "",
            nom: child.nom ?? "",
            prenom: child.prenom,
            displayName: child.displayName,
            avatarUrl: child.avatarUrl.flatMap(URL.init(string:)),
            telephone: parent.telephone,
            dateNaissance: birth,
            sexe: child.sexe.flatMap { Sexe(rawValue: $0.uppercased()) },
            role: "membre",
            isAdmin: false,
            isCoach: false,
            clubId: parent.clubId,
            clubName: parent.clubName,
            classementTennis: child.classementTennis,
            classementPadel: child.classementPadel,
            hasActiveMembership: false,
            activeMembershipPeriod: nil,
            activeMembershipDetails: nil
        )
    }
}
