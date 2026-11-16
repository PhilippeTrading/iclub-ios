//
//  MembershipService.swift
//  iClub
//
//  Formules d'adhésion du club, et souscription depuis l'app.
//
//  Les formules sont tenues par l'administration depuis le web
//  (`membership_formulas`) : l'app les lit, elle ne fixe aucun prix.
//
//  Le paiement en ligne passe par une page Stripe sécurisée (carte, Apple Pay,
//  prélèvement SEPA), créée par la fonction serveur `adhesion-paiement`. La clé
//  secrète Stripe ne quitte jamais le serveur, et c'est le serveur, à la
//  confirmation de Stripe, qui crée l'adhésion : un membre n'a pas le droit
//  d'écrire dans `memberships`, et c'est voulu.
//
//  Contrat détaillé pour l'équipe web : docs/PAIEMENT_ADHESION.md.
//
//  Place dans l'application
//    Écrans d'adhésion (`MembershipViews.swift`) : liste des formules, choix du
//    moyen de paiement, page Stripe ouverte dans une session web sécurisée
//    (`ASWebAuthenticationSession`, qui capte le retour `iclub://adhesion/…`
//    sans type d'URL déclaré), ou coordonnées du secrétariat.
//
//  Tables, fonctions et services externes
//    - Tables `membership_formulas` et `clubs` : lecture publique.
//    - Fonction serveur Supabase `adhesion-paiement` et fonction SQL
//      `demander_adhesion` : Limite connue, ni l'une ni l'autre n'existe dans
//      le dépôt web à ce jour (le seul dossier de `supabase/functions` est
//      `push-message`). L'app le détecte et propose alors de régler au club.
//    - Stripe (Checkout), uniquement à travers la fonction serveur.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//

import Foundation
import Supabase

// MARK: - Modèles

/// Ligne de `membership_formulas` : une formule d'adhésion proposée par le club.
nonisolated struct MembershipFormula: Identifiable, Hashable, Sendable, Decodable {
    /// `id`.
    let id: UUID
    /// `nom` : intitulé de la formule.
    let nom: String
    /// `prix` (`numeric(8, 2)`, euros) ; 0 si absent.
    let prix: Double
    /// `detail` : texte de détail de la formule, saisi par l'administration.
    let detail: String?
    /// `note` : mention complémentaire.
    let note: String?
    /// `sports_inclus` (`text[]`) : sports couverts ; un sport inconnu de
    /// l'app est ignoré.
    let sportsInclus: [Sport]
    /// `avantages_texte` : avantages en texte libre.
    let avantagesTexte: String?
    /// `mensualisable` : la formule peut se régler en mensualités. Faux à
    /// défaut.
    let mensualisable: Bool

    /// Colonnes demandées.
    static let columns = "id, nom, prix, detail, note, sports_inclus, avantages_texte, mensualisable"

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, nom, prix, detail, note, mensualisable
        case sportsInclus = "sports_inclus"
        case avantagesTexte = "avantages_texte"
    }

    /// Décodage tolérant : identifiant et nom obligatoires.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        nom = try c.decode(String.self, forKey: .nom)
        prix = try c.decodeIfPresent(Double.self, forKey: .prix) ?? 0
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        let sports = try c.decodeIfPresent([String].self, forKey: .sportsInclus) ?? []
        sportsInclus = sports.compactMap(Sport.init(rawValue:))
        avantagesTexte = try c.decodeIfPresent(String.self, forKey: .avantagesTexte)
        mensualisable = try c.decodeIfPresent(Bool.self, forKey: .mensualisable) ?? false
    }

    /// « Tennis, Padel », ou `nil` si aucun sport n'est indiqué.
    var sportsLabel: String? {
        sportsInclus.isEmpty ? nil : sportsInclus.map(\.displayName).joined(separator: ", ")
    }
}

/// Ce qu'il faut pour payer au club : où, comment, et qui appeler.
/// (Colonnes de `clubs`.)
nonisolated struct ClubDesk: Sendable, Decodable {
    /// `telephone` du club.
    let telephone: String?
    /// `adresse` du club.
    let adresse: String?
    /// `moyens_paiement_comptoir` (`text[]`) : codes `cb`, `especes`,
    /// `cheque`, `virement`. Vide à défaut.
    let moyensPaiementComptoir: [String]

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case telephone, adresse
        case moyensPaiementComptoir = "moyens_paiement_comptoir"
    }

    /// Décodage tolérant : tout est facultatif.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telephone = try c.decodeIfPresent(String.self, forKey: .telephone)
        adresse = try c.decodeIfPresent(String.self, forKey: .adresse)
        moyensPaiementComptoir = try c.decodeIfPresent([String].self, forKey: .moyensPaiementComptoir) ?? []
    }

    /// « Carte bancaire, espèces, chèque, virement ».
    /// Codes inconnus ignorés ; `nil` si aucun code n'est reconnu.
    var paymentMethodsLabel: String? {
        let labels = moyensPaiementComptoir.compactMap { code -> String? in
            switch code {
            case "cb": "carte bancaire"
            case "especes": "espèces"
            case "cheque": "chèque"
            case "virement": "virement"
            default: nil
            }
        }
        guard let first = labels.first else { return nil }
        // Majuscule au premier mot seulement.
        return ([first.prefix(1).uppercased() + first.dropFirst()] + labels.dropFirst()).joined(separator: ", ")
    }
}

/// Moyen de paiement choisi pour l'adhésion.
/// La valeur brute de `carte` et `sepa` est envoyée à `adhesion-paiement`
/// (champ `mode`).
enum MembershipPaymentMethod: String, CaseIterable, Identifiable {
    /// Carte bancaire, Apple Pay compris, sur la page Stripe.
    case carte
    /// Prélèvement SEPA, sur la page Stripe : confirmé en quelques jours.
    case sepa
    /// Au secrétariat du club.
    case club

    /// Identifiant de liste : la valeur brute.
    var id: String { rawValue }

    /// Titre du choix.
    var title: String {
        switch self {
        case .carte: "Carte ou Apple Pay"
        case .sepa: "Prélèvement SEPA"
        case .club: "Au club"
        }
    }

    /// Explication sous le titre : quand l'adhésion devient active.
    var subtitle: String {
        switch self {
        case .carte: "Paiement sécurisé par Stripe. Adhésion active aussitôt."
        case .sepa: "Depuis votre compte bancaire (IBAN). Adhésion active à la confirmation du prélèvement, sous quelques jours."
        case .club: "Réglez au secrétariat. Le club active votre adhésion à réception."
        }
    }

    /// Pictogramme SF Symbols.
    var symbolName: String {
        switch self {
        case .carte: "creditcard.fill"
        case .sepa: "building.columns.fill"
        case .club: "storefront.fill"
        }
    }
}

/// Erreurs du paiement en ligne de l'adhésion.
enum MembershipServiceError: LocalizedError {
    /// Fonction serveur absente, Stripe non configuré, ou échec sans message :
    /// l'écran propose alors de régler au club.
    case onlinePaymentUnavailable
    /// Refus expliqué par le serveur (message en français).
    case failed(String)

    /// Message affiché.
    var errorDescription: String? {
        switch self {
        case .onlinePaymentUnavailable:
            "Le paiement en ligne n'est pas encore activé par le club. Vous pouvez choisir « Au club »."
        case .failed(let message):
            message
        }
    }
}

// MARK: - Service

/// Formules d'adhésion et souscription.
enum MembershipService {

    /// Retour de la page Stripe vers l'app.
    /// Schéma des adresses de retour (`iclub://adhesion/succes`,
    /// `iclub://adhesion/annule`), capté par la session web sécurisée.
    static let callbackScheme = "iclub"

    /// Formules actives du club, dans l'ordre choisi par l'administration.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: formules triées par `ordre`.
    /// - Throws: l'erreur brute de la requête ou du décodage.
    static func formulas(clubId: UUID) async throws -> [MembershipFormula] {
        try await Supa.client
            .from("membership_formulas")
            .select(MembershipFormula.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("actif", value: true)
            .order("ordre")
            .execute()
            .value
    }

    /// Coordonnées du secrétariat.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: téléphone, adresse et moyens de paiement, ou `nil` en cas
    ///   d'échec.
    static func clubDesk(clubId: UUID) async -> ClubDesk? {
        let rows: [ClubDesk]? = try? await Supa.client
            .from("clubs")
            .select("telephone, adresse, moyens_paiement_comptoir")
            .eq("id", value: clubId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows?.first
    }

    /// Demande au serveur une page de paiement Stripe pour cette formule.
    ///
    /// Le prix n'est pas envoyé : selon le contrat (docs/PAIEMENT_ADHESION.md),
    /// le serveur le relit dans `membership_formulas`.
    ///
    /// - Parameters:
    ///   - formula: formule choisie.
    ///   - method: `carte` ou `sepa`.
    /// - Returns: l'adresse de la page, à ouvrir dans une session web sécurisée.
    /// - Throws: `MembershipServiceError.onlinePaymentUnavailable` (fonction
    ///   absente, Stripe non configuré, réseau, réponse illisible) ou
    ///   `.failed(message)` pour un refus expliqué par le serveur.
    static func startCheckout(formula: MembershipFormula, method: MembershipPaymentMethod) async throws -> URL {
        do {
            // Appel de la fonction serveur avec le jeton de la session (joint
            // par le SDK) ; corps JSON décrit par `CheckoutRequest`.
            let response: CheckoutResponse = try await Supa.client.functions.invoke(
                "adhesion-paiement",
                options: FunctionInvokeOptions(body: CheckoutRequest(
                    formuleId: formula.id,
                    mode: method.rawValue,
                    successUrl: "\(callbackScheme)://adhesion/succes",
                    cancelUrl: "\(callbackScheme)://adhesion/annule"
                ))
            )
            guard let url = URL(string: response.checkoutUrl) else { throw MembershipServiceError.onlinePaymentUnavailable }
            return url
        } catch let error as MembershipServiceError {
            throw error
        } catch let FunctionsError.httpError(code, data) {
            // 404 : la fonction n'est pas déployée. 503 : Stripe pas configuré.
            if code == 404 || code == 503 { throw MembershipServiceError.onlinePaymentUnavailable }
            // Autre code : message `{ "message": … }` du serveur s'il y en a un.
            let message = (try? JSONDecoder().decode(ServerMessage.self, from: data))?.message
            throw MembershipServiceError.failed(message ?? "Le paiement n'a pas pu démarrer. Réessayez dans un instant.")
        } catch {
            // Réseau, décodage : présenté comme une indisponibilité, pour
            // orienter vers le paiement au club.
            throw MembershipServiceError.onlinePaymentUnavailable
        }
    }

    /// Prévient le club qu'on souhaite adhérer et régler sur place.
    ///
    /// - Parameter formula: formule choisie.
    /// - Returns: `false` si la base ne sait pas encore enregistrer la demande
    ///   (`demander_adhesion` absente) : l'app affiche alors seulement les
    ///   informations du secrétariat.
    /// - Throws: `ActivityServiceError` pour un refus de la base ou un échec.
    @discardableResult
    static func requestAtClub(formula: MembershipFormula) async throws -> Bool {
        do {
            // La fonction rend l'identifiant de la demande, inutilisé ici.
            let _: UUID = try await Supa.client
                .rpc("demander_adhesion", params: RequestParams(formuleId: formula.id))
                .execute()
                .value
            return true
        } catch {
            if case .unavailable = ActivityServiceError.from(error) { return false }
            throw ActivityServiceError.from(error)
        }
    }

    // MARK: - Paramètres

    /// Corps envoyé à `adhesion-paiement`.
    private nonisolated struct CheckoutRequest: Encodable, Sendable {
        /// `formule_id`.
        let formuleId: UUID
        /// `mode` : `carte` ou `sepa`.
        let mode: String
        /// `success_url` : retour après paiement.
        let successUrl: String
        /// `cancel_url` : retour après abandon.
        let cancelUrl: String
        /// Noms des champs JSON.
        enum CodingKeys: String, CodingKey {
            case mode
            case formuleId = "formule_id"
            case successUrl = "success_url"
            case cancelUrl = "cancel_url"
        }
    }

    /// Réponse de `adhesion-paiement`.
    private nonisolated struct CheckoutResponse: Decodable, Sendable {
        /// `checkout_url` : adresse de la page Stripe Checkout.
        let checkoutUrl: String
        /// Nom du champ JSON.
        enum CodingKeys: String, CodingKey { case checkoutUrl = "checkout_url" }
    }

    /// Corps d'erreur du serveur.
    private nonisolated struct ServerMessage: Decodable, Sendable {
        /// Message en français, prêt à afficher.
        let message: String?
    }

    /// Paramètre de `demander_adhesion`.
    private nonisolated struct RequestParams: Encodable, Sendable {
        /// `p_formule_id`.
        let formuleId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case formuleId = "p_formule_id" }
    }
}
