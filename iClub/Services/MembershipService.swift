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
//  secrète Stripe ne quitte jamais le serveur, et c'est le serveur — à la
//  confirmation de Stripe — qui crée l'adhésion : un membre n'a pas le droit
//  d'écrire dans `memberships`, et c'est voulu.
//
//  Contrat détaillé pour l'équipe web : docs/PAIEMENT_ADHESION.md.
//

import Foundation
import Supabase

// MARK: - Modèles

nonisolated struct MembershipFormula: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let nom: String
    let prix: Double
    let detail: String?
    let note: String?
    let sportsInclus: [Sport]
    let avantagesTexte: String?
    let mensualisable: Bool

    static let columns = "id, nom, prix, detail, note, sports_inclus, avantages_texte, mensualisable"

    enum CodingKeys: String, CodingKey {
        case id, nom, prix, detail, note, mensualisable
        case sportsInclus = "sports_inclus"
        case avantagesTexte = "avantages_texte"
    }

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

    var sportsLabel: String? {
        sportsInclus.isEmpty ? nil : sportsInclus.map(\.displayName).joined(separator: ", ")
    }
}

/// Ce qu'il faut pour payer au club : où, comment, et qui appeler.
nonisolated struct ClubDesk: Sendable, Decodable {
    let telephone: String?
    let adresse: String?
    let moyensPaiementComptoir: [String]

    enum CodingKeys: String, CodingKey {
        case telephone, adresse
        case moyensPaiementComptoir = "moyens_paiement_comptoir"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telephone = try c.decodeIfPresent(String.self, forKey: .telephone)
        adresse = try c.decodeIfPresent(String.self, forKey: .adresse)
        moyensPaiementComptoir = try c.decodeIfPresent([String].self, forKey: .moyensPaiementComptoir) ?? []
    }

    /// « Carte bancaire, espèces, chèque, virement ».
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
        return ([first.prefix(1).uppercased() + first.dropFirst()] + labels.dropFirst()).joined(separator: ", ")
    }
}

/// Moyen de paiement choisi pour l'adhésion.
enum MembershipPaymentMethod: String, CaseIterable, Identifiable {
    /// Carte bancaire, Apple Pay compris, sur la page Stripe.
    case carte
    /// Prélèvement SEPA, sur la page Stripe : confirmé en quelques jours.
    case sepa
    /// Au secrétariat du club.
    case club

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carte: "Carte ou Apple Pay"
        case .sepa: "Prélèvement SEPA"
        case .club: "Au club"
        }
    }

    var subtitle: String {
        switch self {
        case .carte: "Paiement sécurisé par Stripe. Adhésion active aussitôt."
        case .sepa: "Depuis votre compte bancaire (IBAN). Adhésion active à la confirmation du prélèvement, sous quelques jours."
        case .club: "Réglez au secrétariat. Le club active votre adhésion à réception."
        }
    }

    var symbolName: String {
        switch self {
        case .carte: "creditcard.fill"
        case .sepa: "building.columns.fill"
        case .club: "storefront.fill"
        }
    }
}

enum MembershipServiceError: LocalizedError {
    case onlinePaymentUnavailable
    case failed(String)

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

enum MembershipService {

    /// Retour de la page Stripe vers l'app.
    static let callbackScheme = "iclub"

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
    /// - Returns: l'adresse de la page, à ouvrir dans une session web sécurisée.
    static func startCheckout(formula: MembershipFormula, method: MembershipPaymentMethod) async throws -> URL {
        do {
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
            let message = (try? JSONDecoder().decode(ServerMessage.self, from: data))?.message
            throw MembershipServiceError.failed(message ?? "Le paiement n'a pas pu démarrer. Réessayez dans un instant.")
        } catch {
            throw MembershipServiceError.onlinePaymentUnavailable
        }
    }

    /// Prévient le club qu'on souhaite adhérer et régler sur place.
    ///
    /// - Returns: `false` si la base ne sait pas encore enregistrer la demande
    ///   (`demander_adhesion` absente) : l'app affiche alors seulement les
    ///   informations du secrétariat.
    @discardableResult
    static func requestAtClub(formula: MembershipFormula) async throws -> Bool {
        do {
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

    private nonisolated struct CheckoutRequest: Encodable, Sendable {
        let formuleId: UUID
        let mode: String
        let successUrl: String
        let cancelUrl: String
        enum CodingKeys: String, CodingKey {
            case mode
            case formuleId = "formule_id"
            case successUrl = "success_url"
            case cancelUrl = "cancel_url"
        }
    }

    private nonisolated struct CheckoutResponse: Decodable, Sendable {
        let checkoutUrl: String
        enum CodingKeys: String, CodingKey { case checkoutUrl = "checkout_url" }
    }

    private nonisolated struct ServerMessage: Decodable, Sendable {
        let message: String?
    }

    private nonisolated struct RequestParams: Encodable, Sendable {
        let formuleId: UUID
        enum CodingKeys: String, CodingKey { case formuleId = "p_formule_id" }
    }
}
