//
//  SessionProfile.swift
//  iClub
//
//  Équivalent Swift du `getSessionProfile()` server-side du web : agrège
//  `profiles`, `club_members`, le club et l'adhésion active en un seul objet
//  calculé une fois après connexion, puis rafraîchi après toute mutation
//  pertinente (édition de profil, annulation de réservation…).
//
//  Place dans l'application
//    Construit par `ProfileService.loadSessionProfile`, détenu par
//    `AuthController` (`sessionProfile`, et `activeProfile` qui peut être celui
//    d'un enfant via `SessionProfile.child`). Lu par tous les écrans.
//
//  Points d'attention
//    Valeur figée : elle ne suit pas d'elle-même les changements en base. Après
//    une modification, appeler `AuthController.refreshSessionProfile()`.
//

import Foundation

/// Profil de la personne au nom de qui l'app affiche et agit.
struct SessionProfile: Sendable {
    /// `profiles.id`, identique à `auth.users.id` pour un compte qui se
    /// connecte.
    let id: UUID                       // profiles.id (= auth.users.id)
    /// `club_members.id` : appartenance au club (clé des adhésions et des
    /// crédits invités).
    let clubMemberId: UUID
    /// `profiles.email`, à défaut l'adresse de la session ; vide pour un enfant.
    let email: String
    /// `profiles.nom`, chaîne vide si non renseigné.
    let nom: String
    /// `profiles.prenom`.
    let prenom: String?
    /// Prénom et nom réunis, ou à défaut la partie de l'adresse avant « @ ».
    let displayName: String
    /// Photo de profil (`profiles.avatar_url`), `nil` sans photo : les initiales
    /// la remplacent.
    let avatarUrl: URL?
    /// Numéro normalisé tel qu'il est en base. `nil` pour les comptes créés
    /// avant l'ajout de ce champ : l'app ne suppose jamais qu'un numéro existe.
    let telephone: String?
    /// `profiles.date_naissance`, à minuit local.
    let dateNaissance: Date?
    /// `profiles.sexe`, `nil` si non renseigné.
    let sexe: Sexe?
    /// `club_members.role` (« adherent », « junior »…), « membre » à défaut.
    let role: String
    /// `club_members.is_admin` : administrateur du club.
    let isAdmin: Bool
    /// Entraîneur du club : `club_members.est_entraineur`, ou l'ancien rôle
    /// « entraineur ». La base vérifie tout ; l'app ne fait que montrer ou
    /// cacher l'espace entraîneur.
    var isCoach: Bool = false
    /// `club_members.club_id` : le club de l'app pour cette session.
    let clubId: UUID
    /// `clubs.nom`, « Mon club » à défaut.
    let clubName: String
    /// `club_members.classement_tennis`.
    let classementTennis: String?
    /// `club_members.classement_padel`, de 1,0 à 10,0.
    let classementPadel: Double?
    /// Une ligne `memberships` « à jour » couvre aujourd'hui. Masque les prix
    /// et ouvre les crédits invités.
    let hasActiveMembership: Bool
    /// Début et fin de l'adhésion active (`date_debut`, `date_fin`), `nil` si
    /// aucune ou si une date est illisible. Borne le décompte des crédits
    /// invités.
    let activeMembershipPeriod: (debut: Date, fin: Date)?
    /// Formule et montant (euros) de l'adhésion active, pour l'écran d'adhésion.
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
    /// n'est pas complété, et pas seulement à la création du compte.
    var isComplete: Bool {
        // Un numéro fait d'espaces seulement ne compte pas.
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

/// Compte famille : profil de session reconstitué pour un enfant.
extension SessionProfile {
    /// Le profil d'un enfant vu comme un profil de session, pour que les
    /// onglets lisent et proposent les choses à son nom.
    ///
    /// Ce que la base ne laisse pas lire au parent reste prudent : la date de
    /// naissance est reconstituée depuis l'âge, et l'adhésion de l'enfant est
    /// tenue pour inconnue (donc non active).
    ///
    /// - Parameters:
    ///   - child: ligne de `mes_profils_geres` pour l'enfant.
    ///   - parent: profil de session du parent connecté.
    /// - Returns: un profil qui reprend du parent le club, le téléphone (un
    ///   enfant n'en a pas forcément) et l'appartenance à défaut de la sienne.
    ///   Il n'est ni administrateur ni entraîneur et n'a pas d'adresse. Son
    ///   adhésion étant tenue pour non active, les prix s'affichent en son nom
    ///   et aucun crédit invité ne lui est ouvert.
    static func child(_ child: ManagedProfile, of parent: SessionProfile) -> SessionProfile {
        // Âge révolu retranché de la date du jour : naissance approximative,
        // suffisante pour les contrôles d'âge et l'affichage.
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
