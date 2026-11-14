//
//  AuthController.swift
//  iClub
//
//  Contrôleur de session global, injecté en environnement. Expose le
//  `SessionProfile` courant à toute l'app : c'est l'équivalent mobile du
//  `getSessionProfile()` exécuté côté serveur par le web.
//
//  Rôle
//    Suit l'état d'authentification Supabase (flux `authStateChanges` du SDK),
//    charge le profil de session du membre connecté, gère le compte famille
//    (agir au nom d'un enfant) et expose les actions de connexion, inscription,
//    mot de passe oublié et déconnexion aux écrans.
//
//  Place dans l'application
//    Créé par `iClubApp`, démarré par `RootView` (`.task { auth.start() }`), qui
//    choisit l'écran selon `phase` : lancement, connexion, onglets (ou écran de
//    complétion si le profil est incomplet), écran de blocage. Les onglets lisent
//    `activeProfile` pour savoir au nom de qui ils affichent et agissent.
//
//  Ce qu'il appelle
//    `ProfileService.loadSessionProfile` (tables `profiles`, `club_members`,
//    `clubs`, `memberships`), `AuthService` (Supabase Auth, fonction SQL
//    `join_club_as_member`), `ActivityService.managedProfiles` (fonction SQL
//    `mes_profils_geres`), `PushService.registerCurrentToken` (fonction SQL
//    `enregistrer_appareil`).
//
//  Règles métier
//    - Un compte authentifié sans appartenance à un club est rattaché d'office
//      au club de l'app (`AppConfiguration.clubId`), puis le profil est relu.
//    - Un enfant n'a pas de session : c'est toujours le parent connecté qui écrit
//      en base. Là où une fonction SQL agit au nom de l'enfant (inscription à un
//      cours, terrains fermés, rejoindre une partie), elle vérifie le lien de
//      famille (`peut_agir_pour`) ; une réservation de terrain, elle, est
//      enregistrée au nom du parent (`created_by`).
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage par défaut du
//    projet) : les changements de `phase` et de profil redessinent les vues.
//

import Foundation
import Observation
import Supabase

/// Session de l'utilisateur : phase d'authentification, profil chargé,
/// enfants gérés et personne au nom de qui l'on agit.
@Observable
final class AuthController {

    /// Étape du cycle de vie de la session, lue par `RootView` pour choisir l'écran.
    enum Phase: Equatable {
        /// Lecture de la session persistée au lancement.
        case bootstrapping
        /// Personne n'est connecté : écran de connexion.
        case signedOut
        /// Session ouverte et profil de session chargé (`sessionProfile` non nul).
        case signedIn
        /// Authentifié, mais le profil club n'est pas exploitable
        /// (aucune appartenance, ou erreur de chargement). Le texte est le
        /// message d'erreur affiché, avec un bouton pour réessayer.
        case blocked(String)
    }

    /// Phase courante. Modifiée seulement par ce contrôleur.
    private(set) var phase: Phase = .bootstrapping
    /// Le compte connecté. C'est toujours lui qui écrit en base : un enfant n'a
    /// pas de session, le parent agit pour lui.
    private(set) var sessionProfile: SessionProfile?

    // MARK: - Compte famille

    /// Enfants dont le membre est responsable (`mes_profils_geres`, hors
    /// lui-même). Vide pour un membre sans famille : le sélecteur n'apparaît pas.
    private(set) var managedChildren: [ManagedProfile] = []

    /// Enfant pour qui le parent agit, ou `nil` pour lui-même. Toujours `nil`
    /// à la connexion : on entre sur son propre compte.
    private(set) var actingChildId: UUID?

    /// Profil au nom duquel les onglets lisent et agissent : le compte
    /// connecté, ou l'enfant sélectionné.
    ///
    /// Pour un enfant, le profil est reconstitué par `SessionProfile.child`, à
    /// partir de ce que `mes_profils_geres` laisse lire au parent. `nil` quand
    /// personne n'est connecté.
    var activeProfile: SessionProfile? {
        guard let sessionProfile else { return nil }
        // Aucun enfant choisi, ou enfant disparu de la liste : le compte connecté.
        guard let actingChildId,
              let child = managedChildren.first(where: { $0.profileId == actingChildId })
        else { return sessionProfile }
        return SessionProfile.child(child, of: sessionProfile)
    }

    /// `true` quand les onglets agissent au nom d'un enfant, et non du compte
    /// connecté.
    var isActingForChild: Bool { activeProfile?.id != sessionProfile?.id }

    /// Choisit la personne au nom de qui l'on agit.
    ///
    /// - Parameter childId: identifiant de profil d'un enfant géré, ou `nil`
    ///   pour revenir à soi. Un identifiant qui n'est pas celui d'un enfant
    ///   géré est ignoré et ramène à soi.
    func act(for childId: UUID?) {
        guard childId != actingChildId else { return }
        actingChildId = managedChildren.contains(where: { $0.profileId == childId }) ? childId : nil
    }

    /// Relit la liste des enfants gérés (fonction SQL `mes_profils_geres`).
    /// À rappeler après l'ajout ou le retrait d'un enfant.
    ///
    /// Si l'enfant sélectionné n'est plus dans la liste (lien retiré), on
    /// revient au compte connecté. En cas d'échec de lecture, la liste devient
    /// vide (voir `ActivityService.managedProfiles`).
    func reloadFamily() async {
        guard let profile = sessionProfile else { return }
        managedChildren = await ActivityService.managedProfiles(clubId: profile.clubId).filter { !$0.estMoi }
        if let actingChildId, !managedChildren.contains(where: { $0.profileId == actingChildId }) {
            self.actingChildId = nil
        }
    }

    /// Tâche d'écoute du flux d'authentification, créée par `start()`.
    private var listener: Task<Void, Never>?

    /// Arrête l'écoute si le contrôleur disparaît (en pratique, il vit autant
    /// que l'application).
    deinit { listener?.cancel() }

    // MARK: - Cycle de vie

    /// Démarre l'écoute des changements d'état d'authentification. Supabase
    /// émet `.initialSession` au démarrage, ce qui sort l'app de `.bootstrapping`.
    ///
    /// Idempotent : un second appel (vue recréée) ne crée pas de seconde écoute.
    func start() {
        guard listener == nil else { return }

        listener = Task { [weak self] in
            for await (event, session) in Supa.client.auth.authStateChanges {
                // Référence faible : le contrôleur disparu, l'écoute s'arrête.
                guard let self else { return }
                await self.handle(event: event, session: session)
            }
        }
    }

    /// Réagit à un événement d'authentification du SDK.
    ///
    /// - Parameters:
    ///   - event: événement émis (`initialSession`, `signedIn`, `signedOut`,
    ///     `tokenRefreshed`, `userUpdated`…).
    ///   - session: session courante, `nil` quand personne n'est connecté.
    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .signedOut:
            // Tout ce qui décrit le compte est effacé de la mémoire.
            sessionProfile = nil
            clearFamily()
            phase = .signedOut

        default:
            guard let session else {
                // `.initialSession` sans session : personne n'est connecté.
                if phase == .bootstrapping { phase = .signedOut }
                return
            }

            // Un simple rafraîchissement de jeton ne justifie pas de relire
            // tout le profil.
            if event == .tokenRefreshed, sessionProfile != nil { return }

            // Tout autre événement avec session (connexion, session restaurée
            // au lancement, utilisateur modifié) relit le profil de session.
            await loadProfile(for: session.user)
            if event == .signedIn || event == .initialSession {
                await reloadFamily()
            }
            // Le jeton APNs a pu arriver avant la session : on le rattache au
            // membre dès qu'il est connu.
            if event == .signedIn || event == .initialSession {
                await PushService.registerCurrentToken()
            }
        }
    }

    // MARK: - Profil de session

    /// Charge le profil de session et fixe la phase en conséquence.
    ///
    /// - Parameter user: utilisateur Supabase Auth (`auth.users`) ; son
    ///   identifiant est aussi celui de sa ligne `profiles`.
    ///
    /// Trois issues : profil chargé (`.signedIn`) ; aucune appartenance à un
    /// club (rattachement automatique puis nouvel essai) ; toute autre erreur
    /// (`.blocked` avec le message de l'erreur).
    ///
    /// Attention : appelée aussi par `refreshSessionProfile()` après une
    /// modification. Une coupure réseau à ce moment fait passer l'app sur
    /// l'écran de blocage, avec son bouton « Réessayer ».
    private func loadProfile(for user: User) async {
        do {
            sessionProfile = try await ProfileService.loadSessionProfile(
                userId: user.id,
                email: user.email ?? ""
            )
            phase = .signedIn
        } catch SessionProfileError.noClubMembership {
            await joinClubThenRetry(for: user)
        } catch {
            sessionProfile = nil
            phase = .blocked(error.localizedDescription)
        }
    }

    /// Un compte fraîchement créé n'appartient encore à aucun club, et serait
    /// donc inutilisable : ni planning, ni réservation, ni adhésion visible.
    ///
    /// Le rattachement est tenté ici plutôt qu'après chaque connexion : le
    /// déclencheur est précisément l'absence d'appartenance, ce qui couvre
    /// l'inscription avec session immédiate *et* la confirmation par email
    /// différée, sans ajouter d'aller-retour réseau à chaque lancement.
    ///
    /// - Parameter user: utilisateur sans ligne `club_members`.
    private func joinClubThenRetry(for user: User) async {
        do {
            // Fonction SQL `join_club_as_member` : rôle « adherent », jamais
            // administrateur, fixés côté base.
            try await AuthService.joinClub()
            sessionProfile = try await ProfileService.loadSessionProfile(
                userId: user.id,
                email: user.email ?? ""
            )
            phase = .signedIn
        } catch {
            // Compte valide mais orphelin : on l'explique plutôt que de laisser
            // l'utilisateur sur un écran vide.
            sessionProfile = nil
            phase = .blocked(error.localizedDescription)
        }
    }

    /// À appeler après toute mutation susceptible de changer le profil de
    /// session : édition du profil, changement d'adhésion, annulation.
    /// Sans utilisateur connecté, ne fait rien.
    func refreshSessionProfile() async {
        guard let user = Supa.client.auth.currentUser else { return }
        await loadProfile(for: user)
    }

    /// Nouvelle tentative depuis l'écran d'erreur. Repasse par
    /// `.bootstrapping` (écran de lancement) le temps du chargement ; sans
    /// utilisateur en mémoire, renvoie à l'écran de connexion.
    func retry() async {
        phase = .bootstrapping
        guard let user = Supa.client.auth.currentUser else {
            phase = .signedOut
            return
        }
        await loadProfile(for: user)
    }

    /// Oublie les enfants gérés et revient au compte connecté.
    private func clearFamily() {
        managedChildren = []
        actingChildId = nil
    }

    // MARK: - Actions

    /// Connexion par adresse et mot de passe.
    ///
    /// - Parameters:
    ///   - email: adresse saisie (nettoyée et mise en minuscules par `AuthService`).
    ///   - password: mot de passe saisi, transmis tel quel à Supabase Auth.
    /// - Throws: `AuthServiceError` avec un message prêt à afficher.
    func signIn(email: String, password: String) async throws {
        try await AuthService.signIn(email: email, password: password)
        // La suite est pilotée par `authStateChanges`.
    }

    /// Création de compte.
    ///
    /// - Parameter draft: saisie du formulaire d'inscription.
    /// - Returns: `true` si une session a été ouverte aussitôt, `false` si
    ///   Supabase attend d'abord la confirmation de l'adresse par courriel.
    /// - Throws: `AuthServiceError` avec un message prêt à afficher.
    @discardableResult
    func signUp(_ draft: SignUpDraft) async throws -> Bool {
        try await AuthService.signUp(draft)
    }

    /// Envoie le courriel de réinitialisation du mot de passe.
    ///
    /// - Parameter email: adresse du compte.
    /// - Throws: `AuthServiceError` avec un message prêt à afficher.
    func sendPasswordReset(to email: String) async throws {
        try await AuthService.sendPasswordReset(to: email)
    }

    /// Déconnexion. Une erreur de Supabase est ignorée : l'appareil est
    /// déconnecté localement dans tous les cas.
    func signOut() async {
        try? await AuthService.signOut()
        // On bascule immédiatement plutôt que d'attendre l'événement, pour que
        // l'interface réponde même sans réseau.
        sessionProfile = nil
        clearFamily()
        phase = .signedOut
    }
}
