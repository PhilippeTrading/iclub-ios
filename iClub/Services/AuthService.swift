//
//  AuthService.swift
//  iClub
//
//  Toute la surface Supabase Auth de l'espace membre : connexion, inscription,
//  mot de passe oublié, déconnexion. Aucune vue ne parle directement au SDK.
//

import Foundation
import Supabase
#if canImport(GoogleSignIn)
import GoogleSignIn
import UIKit
#endif

/// Sexe tel que stocké dans `profiles.sexe`, alimenté à l'inscription via les
/// métadonnées passées à `signUp` (trigger `handle_new_user`).
enum Sexe: String, CaseIterable, Identifiable, Codable, Sendable {
    case homme = "H"
    case femme = "F"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .homme: "Homme"
        case .femme: "Femme"
        }
    }
}

/// Saisie du formulaire d'inscription, avec sa propre validation.
struct SignUpDraft {
    var prenom = ""
    var nom = ""
    var email = ""
    var telephone = ""
    var password = ""
    var confirmPassword = ""
    var dateNaissance = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    var sexe: Sexe?

    static let minimumPasswordLength = 8

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isEmailValid: Bool {
        let value = trimmedEmail
        guard value.count > 4, !value.hasPrefix("@"), !value.hasSuffix("@") else { return false }
        let parts = value.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }

    /// Numéro tel qu'il partira en base : chiffres seuls, `+` conservé.
    var normalizedTelephone: String {
        PhoneNumber.normalize(telephone)
    }

    var isTelephoneValid: Bool {
        PhoneNumber.isValid(telephone)
    }

    var isPasswordLongEnough: Bool {
        password.count >= Self.minimumPasswordLength
    }

    var hasUppercase: Bool {
        password.contains(where: \.isUppercase)
    }

    var hasDigit: Bool {
        password.contains(where: \.isNumber)
    }

    /// 8 caractères minimum, au moins une majuscule et au moins un chiffre.
    var isPasswordStrong: Bool {
        isPasswordLongEnough && hasUppercase && hasDigit
    }

    /// Les deux champs doivent correspondre avant toute soumission.
    var passwordsMatch: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    var isValid: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && isEmailValid
            && isTelephoneValid
            && isPasswordStrong
            && passwordsMatch
            && sexe != nil
    }
}

/// Nom transmis par Apple à la première connexion.
nonisolated struct AppleNameUpdate: Encodable, Sendable {
    let prenom: String
    let nom: String
}

/// Paramètre de `join_club_as_member`. Typé plutôt qu'un dictionnaire :
/// `target_club_id` est un `uuid` côté Postgres.
nonisolated struct JoinClubParams: Encodable, Sendable {
    let targetClubId: UUID

    enum CodingKeys: String, CodingKey {
        case targetClubId = "target_club_id"
    }
}

enum AuthServiceError: LocalizedError {
    case invalidCredentials
    case emailNotConfirmed
    case userAlreadyExists
    case weakPassword
    case invalidPhone
    case clubJoinFailed
    case appleUnavailable
    case googleUnavailable
    case accountDeletionUnavailable
    case accountDeletionFailed
    case rateLimited
    case network
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Email ou mot de passe incorrect."
        case .emailNotConfirmed:
            "Ton adresse email n'est pas encore confirmée. Regarde ta boîte de réception."
        case .userAlreadyExists:
            "Un compte existe déjà avec cette adresse email."
        case .weakPassword:
            "Mot de passe trop faible : au moins \(SignUpDraft.minimumPasswordLength) caractères, une majuscule et un chiffre."
        case .invalidPhone:
            PhoneNumber.errorMessage
        case .clubJoinFailed:
            "Compte créé, mais le rattachement au club a échoué — contactez le club."
        case .appleUnavailable:
            "La connexion avec Apple n'est pas encore activée par le club. Utilise ton e-mail et ton mot de passe."
        case .googleUnavailable:
            "La connexion avec Google n'est pas encore activée par le club. Utilise ton e-mail et ton mot de passe."
        case .accountDeletionUnavailable:
            "La suppression de compte n'est pas encore disponible. Contacte le club pour supprimer ton compte."
        case .accountDeletionFailed:
            "La suppression a échoué. Réessayez dans un instant."
        case .rateLimited:
            "Trop de tentatives. Réessaie dans quelques minutes."
        case .network:
            "Connexion impossible. Vérifie ta connexion internet."
        case .other(let message):
            message
        }
    }
}

enum AuthService {

    // MARK: - Connexion

    static func signIn(email: String, password: String) async throws {
        do {
            try await Supa.client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                password: password
            )
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Inscription

    /// Crée le compte et pousse prénom / nom / téléphone / date de naissance /
    /// sexe dans les métadonnées utilisateur, que le trigger `handle_new_user`
    /// recopie dans `profiles`.
    ///
    /// Les clés doivent être exactement celles attendues par le trigger : une
    /// clé mal orthographiée ne provoque aucune erreur, la donnée est
    /// simplement perdue en silence.
    ///
    /// Aucune adhésion n'est créée : c'est un admin qui l'attribue. Le
    /// rattachement au club, lui, passe par `joinClub()`.
    ///
    /// - Returns: `true` si une session a été ouverte immédiatement, `false` si
    ///   Supabase attend d'abord une confirmation par email.
    @discardableResult
    static func signUp(_ draft: SignUpDraft) async throws -> Bool {
        guard let sexe = draft.sexe else {
            throw AuthServiceError.other("Merci d'indiquer ton sexe.")
        }
        guard draft.isTelephoneValid else {
            throw AuthServiceError.invalidPhone
        }

        do {
            let response = try await Supa.client.auth.signUp(
                email: draft.trimmedEmail,
                password: draft.password,
                data: [
                    "prenom": .string(draft.prenom.trimmingCharacters(in: .whitespaces)),
                    "nom": .string(draft.nom.trimmingCharacters(in: .whitespaces)),
                    // Version normalisée, jamais la saisie brute.
                    "telephone": .string(draft.normalizedTelephone),
                    "date_naissance": .string(SupabaseDate.day(from: draft.dateNaissance)),
                    "sexe": .string(sexe.rawValue),
                ]
            )
            return response.session != nil
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Rattachement au club

    /// Inscrit l'utilisateur connecté comme simple adhérent du club.
    ///
    /// Les règles de sécurité interdisent d'insérer soi-même sa ligne dans
    /// `club_members` — sinon n'importe qui pourrait se rattacher à n'importe
    /// quel club, voire se donner des droits. Le rôle et l'absence de droits
    /// administrateur sont fixés côté base et ne peuvent pas être influencés
    /// depuis l'app.
    ///
    /// Sans effet si le membre est déjà rattaché : l'appel peut donc être
    /// relancé après n'importe quelle connexion.
    static func joinClub() async throws {
        guard let clubId = AppConfiguration.clubId else {
            throw AuthServiceError.clubJoinFailed
        }

        do {
            try await Supa.client
                .rpc("join_club_as_member", params: JoinClubParams(targetClubId: clubId))
                .execute()
        } catch {
            throw AuthServiceError.clubJoinFailed
        }
    }

    // MARK: - Connexion avec Apple

    /// Échange le jeton d'identité Apple contre une session Supabase.
    ///
    /// - Parameters:
    ///   - rawNonce: nonce **en clair**. Apple reçoit son empreinte SHA-256 au
    ///     moment de la demande ; Supabase reçoit la valeur en clair et vérifie
    ///     qu'elle correspond à l'empreinte signée dans le jeton. C'est ce qui
    ///     empêche de rejouer un jeton intercepté.
    ///   - fullName: transmis par Apple **uniquement à la toute première
    ///     connexion**. On l'écrit aussitôt dans le profil, faute de quoi il
    ///     serait perdu définitivement.
    static func signInWithApple(
        idToken: String,
        rawNonce: String,
        fullName: PersonNameComponents?
    ) async throws {
        do {
            let session = try await Supa.client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )

            await saveProviderIdentity(
                prenom: fullName?.givenName,
                nom: fullName?.familyName,
                avatarURL: nil,
                profileId: session.user.id
            )
        } catch {
            throw mappedProvider(error, unavailable: .appleUnavailable)
        }
    }

    /// Reporte dans le profil ce que le fournisseur a transmis — prénom, nom,
    /// photo — **sans jamais écraser** une valeur déjà présente.
    ///
    /// La ligne `profiles` est créée par le déclencheur `handle_new_user` : on
    /// ne l'écrit pas ici, on complète seulement ses champs vides. Téléphone,
    /// date de naissance et sexe ne sont fournis ni par Apple ni par Google :
    /// c'est l'écran de complétion qui les demande.
    private static func saveProviderIdentity(
        prenom: String?,
        nom: String?,
        avatarURL: URL?,
        profileId: UUID
    ) async {
        let prenom = prenom?.trimmingCharacters(in: .whitespaces) ?? ""
        let nom = nom?.trimmingCharacters(in: .whitespaces) ?? ""

        if !prenom.isEmpty || !nom.isEmpty {
            _ = try? await Supa.client
                .from("profiles")
                .update(AppleNameUpdate(prenom: prenom, nom: nom))
                .eq("id", value: profileId.uuidString)
                .or("prenom.is.null,prenom.eq.")
                .execute()
        }

        if let avatarURL {
            _ = try? await Supa.client
                .from("profiles")
                .update(AvatarUpdate(avatarUrl: avatarURL.absoluteString))
                .eq("id", value: profileId.uuidString)
                .or("avatar_url.is.null,avatar_url.eq.")
                .execute()
        }
    }

    private static func mappedProvider(_ error: any Error, unavailable: AuthServiceError) -> AuthServiceError {
        let message = String(describing: error).lowercased()
        // Fournisseur non activé dans le tableau de bord Supabase : on le dit
        // clairement plutôt que de remonter « provider is not enabled ».
        if message.contains("provider is not enabled") || message.contains("unsupported provider") {
            return unavailable
        }
        return mapped(error)
    }

    // MARK: - Connexion avec Google
    //
    // EN SOMMEIL, volontairement — ne pas supprimer comme du code mort.
    // La connexion Google est repoussée (décision produit), pas abandonnée.
    // Tout ce bloc est derrière `#if canImport(GoogleSignIn)` : il est inerte
    // tant que le paquet GoogleSignIn-iOS n'est pas dans le projet, et
    // s'activera de lui-même le jour où il y sera ajouté.
    //
    // Pour le réactiver, trois étapes et rien d'autre :
    //   1. ajouter le paquet GoogleSignIn-iOS (produits GoogleSignIn et
    //      GoogleSignInSwift) ;
    //   2. renseigner `AppConfiguration.googleIOSClientID` et le type d'URL
    //      (identifiant client inversé) dans Info ;
    //   3. activer le fournisseur Google dans Supabase, avec les identifiants
    //      iOS et web dans « Client IDs ».

    /// Le SDK GoogleSignIn est derrière `canImport` : l'app compile sans lui,
    /// et le bouton n'apparaît qu'une fois le paquet ajouté au projet.
    static var isGoogleSignInAvailable: Bool {
        #if canImport(GoogleSignIn)
        return true
        #else
        return false
        #endif
    }

    /// Flux natif : feuille Google, puis échange du jeton d'identité contre une
    /// session Supabase. Aucune vue web, aucune sortie de l'application.
    ///
    /// - Returns: `false` si l'utilisateur a fermé la feuille Google — ce n'est
    ///   pas une erreur, l'écran ne doit rien afficher.
    @discardableResult
    static func signInWithGoogle() async throws -> Bool {
        #if canImport(GoogleSignIn)
        guard let clientID = AppConfiguration.googleIOSClientID else {
            throw AuthServiceError.googleUnavailable
        }
        guard let presenter = topViewController() else {
            throw AuthServiceError.other("Impossible d'ouvrir la connexion Google.")
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            if (error as NSError).code == GIDSignInError.Code.canceled.rawValue { return false }
            throw mapped(error)
        }

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.other("Google n'a pas renvoyé d'identifiant exploitable. Réessaie.")
        }

        do {
            let session = try await Supa.client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .google,
                    idToken: idToken,
                    accessToken: result.user.accessToken.tokenString
                )
            )

            await saveProviderIdentity(
                prenom: result.user.profile?.givenName,
                nom: result.user.profile?.familyName,
                avatarURL: result.user.profile?.imageURL(withDimension: 512),
                profileId: session.user.id
            )
        } catch {
            throw mappedProvider(error, unavailable: .googleUnavailable)
        }
        return true
        #else
        throw AuthServiceError.googleUnavailable
        #endif
    }

    #if canImport(GoogleSignIn)
    /// Contrôleur au sommet de la fenêtre active, requis par le SDK Google.
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif

    // MARK: - Suppression du compte

    /// Supprime le compte de l'utilisateur connecté.
    ///
    /// Tout le travail est fait côté base, de façon atomique, par
    /// `delete_my_account()` : annulation des réservations à venir, retrait des
    /// parties, anonymisation de l'historique, effacement du profil puis de
    /// `auth.users`. La fonction n'agit que sur `auth.uid()`.
    ///
    /// Rien n'est supprimé directement depuis le téléphone : une suppression
    /// partielle, interrompue par une coupure réseau, laisserait des données
    /// incohérentes.
    static func deleteMyAccount(profileId: UUID) async throws {
        // 1. Les fichiers d'abord : après l'appel, plus rien ne les référence.
        await AvatarService.deleteAllFiles(profileId: profileId)

        // L'appareil est oublié tant que la session est encore valide ; il est
        // réenregistré si la suppression échoue.
        await PushService.forgetDevice()
        await AttendanceReminders.clear()
        await BookingReminders.clear()

        // 2. La suppression elle-même.
        do {
            try await Supa.client.rpc("delete_my_account").execute()
        } catch {
            await PushService.registerCurrentToken()
            throw mappedDeletionError(error)
        }

        // 3. La session est déjà invalide côté serveur ; on la ferme ici et on
        // efface ce que l'appareil garde du compte.
        signOutOfProviders()
        MessagingCenter.shared.reset()
        try? await Supa.client.auth.signOut()
        clearLocalCaches()
    }

    private static func mappedDeletionError(_ error: Error) -> AuthServiceError {
        switch (error as? PostgrestError)?.code {
        case "PGRST202":
            // Fonction absente : la migration n'a pas été exécutée.
            return .accountDeletionUnavailable
        case "P0001":
            // Refus métier (dernier administrateur du club) : message rédigé
            // pour être lu tel quel.
            return .other((error as? PostgrestError)?.message ?? "")
        default:
            // Jamais de détail technique sur une opération aussi sensible.
            return .accountDeletionFailed
        }
    }

    /// Les photos de profil passent par `AsyncImage`, qui met en cache via
    /// `URLCache.shared` — mémoire **et** disque. On vide tout : l'application
    /// ne doit garder aucune trace d'un compte supprimé.
    private static func clearLocalCaches() {
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Mot de passe oublié

    static func sendPasswordReset(to email: String) async throws {
        do {
            try await Supa.client.auth.resetPasswordForEmail(
                email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                redirectTo: AppConfiguration.passwordResetRedirect
            )
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Déconnexion

    static func signOut() async throws {
        // En premier, et même si Supabase échoue : sinon la session Google
        // reste active, et le prochain appui reconnecte le même compte sans
        // laisser choisir.
        signOutOfProviders()
        // Tant que la session est valide : l'appareil ne doit plus recevoir
        // les notifications du membre qui s'en va.
        await PushService.forgetDevice()
        await AttendanceReminders.clear()
        await BookingReminders.clear()
        MessagingCenter.shared.reset()
        do {
            try await Supa.client.auth.signOut()
        } catch {
            throw mapped(error)
        }
    }

    /// Ferme la session des fournisseurs tiers qui en gardent une côté
    /// appareil. Apple n'en garde pas : rien à faire pour lui.
    private static func signOutOfProviders() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    // MARK: - Traduction des erreurs

    /// Traduit les erreurs du SDK en messages affichables. On s'appuie sur le
    /// message renvoyé par GoTrue plutôt que sur une énumération du SDK, pour
    /// rester stable d'une version du SDK à l'autre.
    private static func mapped(_ error: any Error) -> AuthServiceError {
        if let error = error as? AuthServiceError { return error }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return .network
            default:
                break
            }
        }

        let message = String(describing: error).lowercased()

        if message.contains("invalid login credentials") { return .invalidCredentials }
        if message.contains("email not confirmed") { return .emailNotConfirmed }
        if message.contains("already registered") || message.contains("already exists") {
            return .userAlreadyExists
        }
        if message.contains("password should be") || message.contains("weak password") {
            return .weakPassword
        }
        if message.contains("rate limit") || message.contains("too many requests") {
            return .rateLimited
        }

        return .other(error.localizedDescription)
    }
}
