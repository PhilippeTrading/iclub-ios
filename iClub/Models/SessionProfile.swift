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
