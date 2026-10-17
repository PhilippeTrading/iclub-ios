//
//  AuthController.swift
//  iClub
//
//  Contrôleur de session global, injecté en environnement. Expose le
//  `SessionProfile` courant à toute l'app — équivalent mobile du
//  `getSessionProfile()` server-side du web.
//

import Foundation
import Observation
import Supabase

@Observable
final class AuthController {

    enum Phase: Equatable {
        /// Lecture de la session persistée au lancement.
        case bootstrapping
        case signedOut
        case signedIn
        /// Authentifié, mais le profil club n'est pas exploitable
        /// (aucune appartenance, ou erreur de chargement).
        case blocked(String)
    }

    private(set) var phase: Phase = .bootstrapping
    private(set) var sessionProfile: SessionProfile?

    private var listener: Task<Void, Never>?

    deinit { listener?.cancel() }

    // MARK: - Cycle de vie

    /// Démarre l'écoute des changements d'état d'authentification. Supabase
    /// émet `.initialSession` au démarrage, ce qui sort l'app de `.bootstrapping`.
    func start() {
        guard listener == nil else { return }

        listener = Task { [weak self] in
            for await (event, session) in Supa.client.auth.authStateChanges {
                guard let self else { return }
                await self.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .signedOut:
            sessionProfile = nil
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

            await loadProfile(for: session.user)
        }
    }

    // MARK: - Profil de session

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
    private func joinClubThenRetry(for user: User) async {
        do {
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
    func refreshSessionProfile() async {
        guard let user = Supa.client.auth.currentUser else { return }
        await loadProfile(for: user)
    }

    /// Nouvelle tentative depuis l'écran d'erreur.
    func retry() async {
        phase = .bootstrapping
        guard let user = Supa.client.auth.currentUser else {
            phase = .signedOut
            return
        }
        await loadProfile(for: user)
    }

    // MARK: - Actions

    func signIn(email: String, password: String) async throws {
        try await AuthService.signIn(email: email, password: password)
        // La suite est pilotée par `authStateChanges`.
    }

    @discardableResult
    func signUp(_ draft: SignUpDraft) async throws -> Bool {
        try await AuthService.signUp(draft)
    }

    func sendPasswordReset(to email: String) async throws {
        try await AuthService.sendPasswordReset(to: email)
    }

    func signOut() async {
        try? await AuthService.signOut()
        // On bascule immédiatement plutôt que d'attendre l'événement, pour que
        // l'interface réponde même sans réseau.
        sessionProfile = nil
        phase = .signedOut
    }
}
