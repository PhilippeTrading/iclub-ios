//
//  AuthService.swift
//  iClub
//
//  Toute la surface Supabase Auth de l'espace membre : connexion, inscription,
//  mot de passe oublié, déconnexion. Aucune vue ne parle directement au SDK.
//
//  Rôle
//    Connexion par adresse et mot de passe, inscription, rattachement au club,
//    connexion avec Apple (et avec Google, en sommeil), mot de passe oublié,
//    déconnexion, suppression du compte, et traduction des erreurs du SDK en
//    messages français.
//
//  Place dans l'application
//    `AuthController` (connexion, inscription, mot de passe oublié,
//    déconnexion, rattachement automatique), `AppleSignInButton`,
//    `GoogleSignInButtonView`, `SignInView` (présence du bouton Google),
//    `ProfileView` (suppression du compte).
//
//  Services, tables et fonctions SQL
//    - Supabase Auth (GoTrue) : `signIn`, `signUp`, `signInWithIdToken` (Apple,
//      Google), `resetPasswordForEmail`, `signOut`.
//    - Déclencheur `handle_new_user` sur `auth.users` : crée la ligne
//      `profiles` à partir des métadonnées de l'inscription.
//    - `join_club_as_member(target_club_id)` : rattachement comme adhérent.
//    - `delete_my_account()` (migration `20261017100000_suppression_de_compte.sql`).
//    - Table `profiles` : nom transmis par Apple, photo transmise par Google
//      (RLS : sa propre ligne).
//
//  Effets de bord
//    Déconnexion et suppression : appareil oublié pour les notifications,
//    rappels locaux effacés, messagerie remise à zéro ; la suppression vide
//    aussi les fichiers de la photo et le cache des images.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones. La
//    session est conservée et rafraîchie par le SDK.
//

import Foundation
import Supabase
#if canImport(GoogleSignIn)
import GoogleSignIn
import UIKit
#endif

/// Sexe tel que stocké dans `profiles.sexe`, alimenté à l'inscription via les
/// métadonnées passées à `signUp` (trigger `handle_new_user`).
/// (Contrainte `check` de la colonne : « H » ou « F ».)
enum Sexe: String, CaseIterable, Identifiable, Codable, Sendable {
    /// « H ».
    case homme = "H"
    /// « F ».
    case femme = "F"

    /// Identifiant de liste : la valeur brute.
    var id: String { rawValue }

    /// Libellé affiché (« Homme », « Femme »).
    var displayName: String {
        switch self {
        case .homme: "Homme"
        case .femme: "Femme"
        }
    }
}

/// Saisie du formulaire d'inscription, avec sa propre validation.
struct SignUpDraft {
    /// Prénom saisi.
    var prenom = ""
    /// Nom saisi.
    var nom = ""
    /// Adresse saisie (voir `trimmedEmail`).
    var email = ""
    /// Téléphone saisi, brut (voir `normalizedTelephone`).
    var telephone = ""
    /// Mot de passe.
    var password = ""
    /// Confirmation du mot de passe.
    var confirmPassword = ""
    /// Date de naissance ; le sélecteur part de trente ans avant aujourd'hui.
    var dateNaissance = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    /// Sexe, obligatoire pour s'inscrire (mixité des parties ouvertes).
    var sexe: Sexe?

    /// Longueur minimale du mot de passe, en caractères.
    static let minimumPasswordLength = 8

    /// Adresse sans espaces de bord, en minuscules : la forme envoyée à Supabase.
    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Contrôle de forme simple : plus de 4 caractères, un seul « @ » ni en
    /// tête ni en fin, un point dans la partie domaine qui ne la termine pas.
    /// Supabase Auth refait sa propre validation.
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

    /// Le numéro a l'un des deux formats acceptés (voir `PhoneNumber.isValid`).
    var isTelephoneValid: Bool {
        PhoneNumber.isValid(telephone)
    }

    /// Au moins `minimumPasswordLength` caractères.
    var isPasswordLongEnough: Bool {
        password.count >= Self.minimumPasswordLength
    }

    /// Au moins une lettre majuscule.
    var hasUppercase: Bool {
        password.contains(where: \.isUppercase)
    }

    /// Au moins un chiffre.
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

    /// Toutes les conditions réunies : le bouton d'inscription s'active.
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
/// (Mise à jour de `profiles` ; synthétisé : clés `prenom` et `nom`.)
nonisolated struct AppleNameUpdate: Encodable, Sendable {
    /// `profiles.prenom`.
    let prenom: String
    /// `profiles.nom`.
    let nom: String
}

/// Paramètre de `join_club_as_member`. Typé plutôt qu'un dictionnaire :
/// `target_club_id` est un `uuid` côté Postgres.
nonisolated struct JoinClubParams: Encodable, Sendable {
    /// Club de rattachement (`AppConfiguration.clubId`).
    let targetClubId: UUID

    /// Nom du paramètre SQL.
    enum CodingKeys: String, CodingKey {
        case targetClubId = "target_club_id"
    }
}

/// Erreurs d'authentification, avec leur message affichable.
enum AuthServiceError: LocalizedError {
    /// Adresse ou mot de passe faux.
    case invalidCredentials
    /// Compte créé mais adresse pas encore confirmée.
    case emailNotConfirmed
    /// Un compte existe déjà avec cette adresse.
    case userAlreadyExists
    /// Mot de passe refusé par Supabase Auth.
    case weakPassword
    /// Numéro de téléphone au mauvais format.
    case invalidPhone
    /// Rattachement au club impossible (`join_club_as_member`).
    case clubJoinFailed
    /// Fournisseur Apple non activé dans Supabase.
    case appleUnavailable
    /// Connexion Google non disponible (paquet absent, identifiant manquant
    /// ou fournisseur non activé).
    case googleUnavailable
    /// `delete_my_account` absente de la base.
    case accountDeletionUnavailable
    /// Échec de la suppression, sans détail.
    case accountDeletionFailed
    /// Trop de tentatives (limite de débit de Supabase Auth).
    case rateLimited
    /// Pas de réseau, ou serveur injoignable.
    case network
    /// Autre erreur, avec son message.
    case other(String)

    /// Message montré à l'utilisateur.
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

/// Authentification et cycle de vie du compte.
enum AuthService {

    // MARK: - Connexion

    /// Connexion par adresse et mot de passe. La session obtenue est conservée
    /// par le SDK, qui émet `.signedIn` : `AuthController` prend la suite.
    ///
    /// - Parameters:
    ///   - email: adresse saisie (espaces retirés, mise en minuscules).
    ///   - password: mot de passe, transmis tel quel.
    /// - Throws: `AuthServiceError` traduite par `mapped`.
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
    /// Aucune adresse de retour n'est passée : le lien de confirmation du
    /// courriel, s'il est exigé, renvoie vers l'adresse par défaut du projet
    /// Supabase.
    ///
    /// - Parameter draft: saisie du formulaire, déjà validée par l'écran.
    /// - Returns: `true` si une session a été ouverte immédiatement, `false` si
    ///   Supabase attend d'abord une confirmation par email.
    /// - Throws: `AuthServiceError` (sexe manquant, téléphone invalide, compte
    ///   existant, mot de passe trop faible, réseau…).
    @discardableResult
    static func signUp(_ draft: SignUpDraft) async throws -> Bool {
        // Garde-fous repris du formulaire : la base ne contrôle ni le sexe
        // absent ni le format du numéro.
        guard let sexe = draft.sexe else {
            throw AuthServiceError.other("Merci d'indiquer ton sexe.")
        }
        guard draft.isTelephoneValid else {
            throw AuthServiceError.invalidPhone
        }

        do {
            // Métadonnées utilisateur (`raw_user_meta_data`), lues par le
            // déclencheur `handle_new_user` : clés `prenom`, `nom`, `telephone`,
            // `date_naissance` (« AAAA-MM-JJ ») et `sexe` (« H » ou « F »).
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
            // Session présente : la confirmation par courriel n'est pas exigée
            // par le projet ; l'événement `.signedIn` suit.
            return response.session != nil
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Rattachement au club

    /// Inscrit l'utilisateur connecté comme simple adhérent du club.
    ///
    /// Les règles de sécurité interdisent d'insérer soi-même sa ligne dans
    /// `club_members` : sinon n'importe qui pourrait se rattacher à n'importe
    /// quel club, voire se donner des droits. Le rôle et l'absence de droits
    /// administrateur sont fixés côté base et ne peuvent pas être influencés
    /// depuis l'app.
    ///
    /// Sans effet si le membre est déjà rattaché : l'appel peut donc être
    /// relancé après n'importe quelle connexion.
    ///
    /// La fonction `join_club_as_member` exige une session, un club actif, et
    /// écrit le rôle `adherent`, `is_admin = false` et l'invitation
    /// « compte activé » (`on conflict do nothing`).
    ///
    /// - Throws: `AuthServiceError.clubJoinFailed`, quelle que soit la cause
    ///   (identifiant de club absent, club inactif, réseau).
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
    ///   - idToken: jeton d'identité signé par Apple.
    /// - Throws: `AuthServiceError.appleUnavailable` si le fournisseur Apple
    ///   n'est pas activé dans Supabase, sinon l'erreur traduite par `mapped`.
    ///
    /// Un compte Apple neuf passe par le déclencheur `handle_new_user` (profil
    /// créé avec l'adresse fournie par Apple, éventuellement masquée), puis par
    /// le rattachement automatique au club et l'écran de complétion du profil.
    static func signInWithApple(
        idToken: String,
        rawNonce: String,
        fullName: PersonNameComponents?
    ) async throws {
        do {
            // Échange du jeton Apple contre une session Supabase ; GoTrue
            // vérifie la signature et le nonce.
            let session = try await Supa.client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )

            // Apple ne fournit jamais de photo.
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

    /// Reporte dans le profil ce que le fournisseur a transmis (prénom, nom,
    /// photo) **sans jamais écraser** une valeur déjà présente.
    ///
    /// La ligne `profiles` est créée par le déclencheur `handle_new_user` : on
    /// ne l'écrit pas ici, on complète seulement ses champs vides. Téléphone,
    /// date de naissance et sexe ne sont fournis ni par Apple ni par Google :
    /// c'est l'écran de complétion qui les demande.
    ///
    /// Les écritures sont silencieuses (`try?`) : un échec laisse le profil tel
    /// quel, et l'écran de complétion demandera ce qui manque.
    ///
    /// Limite connue : la condition ne regarde que `prenom`. Si le prénom est
    /// vide mais le nom déjà rempli, le nom est réécrit avec celui du
    /// fournisseur (éventuellement vide) ; si le prénom est rempli, un nom vide
    /// n'est pas complété.
    ///
    /// - Parameters:
    ///   - prenom: prénom transmis, `nil` s'il ne l'est pas.
    ///   - nom: nom transmis.
    ///   - avatarURL: photo transmise (Google), `nil` pour Apple.
    ///   - profileId: profil de la session qui vient de s'ouvrir.
    private static func saveProviderIdentity(
        prenom: String?,
        nom: String?,
        avatarURL: URL?,
        profileId: UUID
    ) async {
        let prenom = prenom?.trimmingCharacters(in: .whitespaces) ?? ""
        let nom = nom?.trimmingCharacters(in: .whitespaces) ?? ""

        if !prenom.isEmpty || !nom.isEmpty {
            // Seulement si le prénom en base est nul ou vide (`prenom.eq.` :
            // égal à la chaîne vide).
            _ = try? await Supa.client
                .from("profiles")
                .update(AppleNameUpdate(prenom: prenom, nom: nom))
                .eq("id", value: profileId.uuidString)
                .or("prenom.is.null,prenom.eq.")
                .execute()
        }

        if let avatarURL {
            // Seulement si aucune photo n'est enregistrée.
            _ = try? await Supa.client
                .from("profiles")
                .update(AvatarUpdate(avatarUrl: avatarURL.absoluteString))
                .eq("id", value: profileId.uuidString)
                .or("avatar_url.is.null,avatar_url.eq.")
                .execute()
        }
    }

    /// Traduction des erreurs d'une connexion par fournisseur tiers.
    ///
    /// - Parameters:
    ///   - error: erreur du SDK.
    ///   - unavailable: erreur à rendre si le fournisseur n'est pas activé.
    /// - Returns: `unavailable`, ou la traduction générale de `mapped`.
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
    // EN SOMMEIL, volontairement : ne pas supprimer comme du code mort.
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
    /// - Returns: `false` si l'utilisateur a fermé la feuille Google : ce n'est
    ///   pas une erreur, l'écran ne doit rien afficher.
    /// - Throws: `AuthServiceError.googleUnavailable` (paquet absent, identifiant
    ///   non renseigné, fournisseur non activé), `.other` (feuille impossible à
    ///   présenter, jeton absent) ou une erreur traduite par `mapped`.
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

        // 1. La feuille Google.
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            // Fermeture par l'utilisateur : pas une erreur.
            if (error as NSError).code == GIDSignInError.Code.canceled.rawValue { return false }
            throw mapped(error)
        }

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.other("Google n'a pas renvoyé d'identifiant exploitable. Réessaie.")
        }

        // 2. L'échange contre une session Supabase, puis le profil complété
        //    (photo demandée en 512 pixels).
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
        // Paquet absent (cas actuel) : la connexion Google n'est pas possible.
        throw AuthServiceError.googleUnavailable
        #endif
    }

    #if canImport(GoogleSignIn)
    /// Contrôleur au sommet de la fenêtre active, requis par le SDK Google.
    ///
    /// - Returns: le contrôleur présenté le plus haut de la fenêtre principale,
    ///   ou `nil` sans fenêtre active.
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
    ///
    /// L'historique du club (réservations passées, adhésions, comptabilité)
    /// est conservé mais n'est plus rattachable à la personne. La fonction
    /// refuse la suppression du seul administrateur d'un club.
    ///
    /// - Parameter profileId: profil du membre connecté (dossier de photos à
    ///   effacer).
    /// - Throws: `AuthServiceError.accountDeletionUnavailable` (fonction
    ///   absente), `.other(message)` (refus rédigé de la base) ou
    ///   `.accountDeletionFailed`.
    static func deleteMyAccount(profileId: UUID) async throws {
        // 1. Les fichiers d'abord : après l'appel, plus rien ne les référence.
        await AvatarService.deleteAllFiles(profileId: profileId)

        // L'appareil est oublié tant que la session est encore valide ; il est
        // réenregistré si la suppression échoue. Les rappels locaux (appel de
        // l'entraîneur, réservations) sont retirés de l'appareil.
        await PushService.forgetDevice()
        await AttendanceReminders.clear()
        await BookingReminders.clear()

        // 2. La suppression elle-même.
        do {
            try await Supa.client.rpc("delete_my_account").execute()
        } catch {
            // Échec : le compte existe toujours, l'appareil est réenregistré.
            // (Les rappels locaux effacés ne sont pas reprogrammés ici.)
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

    /// Traduction des erreurs de `delete_my_account`.
    ///
    /// - Parameter error: erreur de l'appel.
    /// - Returns: indisponible, refus rédigé, ou échec générique.
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
    /// `URLCache.shared`, en mémoire **et** sur disque. On vide tout : l'application
    /// ne doit garder aucune trace d'un compte supprimé.
    private static func clearLocalCaches() {
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Mot de passe oublié

    /// Demande à Supabase Auth le courriel de réinitialisation du mot de passe.
    ///
    /// Limite connue : le lien du courriel renvoie vers
    /// `AppConfiguration.passwordResetRedirect` (`iclub://reset-password`), que
    /// l'app ne sait pas ouvrir à ce jour (voir AppConfiguration.swift).
    ///
    /// - Parameter email: adresse saisie (espaces retirés, mise en minuscules).
    /// - Throws: `AuthServiceError` traduite par `mapped` (réseau, trop de
    ///   tentatives…).
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

    /// Ferme la session du membre et efface de l'appareil ce qui le concerne
    /// (notifications, rappels locaux, messagerie).
    ///
    /// - Throws: l'erreur de `auth.signOut()` traduite par `mapped` ; le
    ///   nettoyage local a déjà eu lieu à ce moment.
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
    ///
    /// - Parameter error: erreur quelconque.
    /// - Returns: l'erreur elle-même si c'est déjà une `AuthServiceError` ; une
    ///   erreur réseau reconnue ; une erreur reconnue dans le texte du message ;
    ///   à défaut `.other` avec la description de l'erreur.
    private static func mapped(_ error: any Error) -> AuthServiceError {
        if let error = error as? AuthServiceError { return error }

        // Erreurs de transport : pas de réseau, coupure, délai, hôte injoignable.
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return .network
            default:
                break
            }
        }

        // Reconnaissance par fragments du message de GoTrue, en minuscules.
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
