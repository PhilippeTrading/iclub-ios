//
//  MemberDocuments.swift
//  iClub
//
//  Pièces demandées par le club (`types_documents`, `documents_adherent`) et
//  documents comptables (`documents_comptables`). Même vocabulaire que le web.
//

import Foundation

// MARK: - Types de pièces

nonisolated enum DocumentAudience: String, Sendable, Decodable {
    case tous, mineurs, majeurs, competiteurs
}

nonisolated struct DocumentType: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let libelle: String
    let obligatoire: Bool
    let dureeValiditeMois: Int?
    let concerne: DocumentAudience
    /// Pièce de santé : jamais d'aperçu hors de l'écran de dépôt.
    let sensible: Bool

    static let columns = "id, libelle, obligatoire, duree_validite_mois, concerne, sensible"

    enum CodingKeys: String, CodingKey {
        case id, libelle, obligatoire, concerne, sensible
        case dureeValiditeMois = "duree_validite_mois"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        libelle = try c.decode(String.self, forKey: .libelle)
        obligatoire = try c.decodeIfPresent(Bool.self, forKey: .obligatoire) ?? true
        dureeValiditeMois = try c.decodeIfPresent(Int.self, forKey: .dureeValiditeMois)
        concerne = (try? c.decode(DocumentAudience.self, forKey: .concerne)) ?? .tous
        sensible = try c.decodeIfPresent(Bool.self, forKey: .sensible) ?? false
    }

    /// Mêmes règles que le web : « compétiteurs » n'est jamais filtré, faute
    /// de savoir qui joue en compétition.
    func concerns(age: Int?) -> Bool {
        switch concerne {
        case .mineurs: if let age { age < 18 } else { false }
        case .majeurs: age.map { $0 >= 18 } ?? true
        case .tous, .competiteurs: true
        }
    }
}

// MARK: - Pièce déposée

nonisolated enum DocumentStatus: String, Sendable, Decodable {
    case enAttente = "en_attente"
    case valide
    case refuse
}

nonisolated struct MemberDocument: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let profileId: UUID
    let typeDocumentId: UUID
    let fichierChemin: String
    let nomFichier: String
    let dateDocument: Date?
    let dateExpiration: Date?
    let statut: DocumentStatus
    let motifRefus: String?
    let deposeLe: Date?

    static let columns = "id, profile_id, type_document_id, fichier_chemin, nom_fichier, date_document, date_expiration, statut, motif_refus, depose_le"

    enum CodingKeys: String, CodingKey {
        case id, statut
        case profileId = "profile_id"
        case typeDocumentId = "type_document_id"
        case fichierChemin = "fichier_chemin"
        case nomFichier = "nom_fichier"
        case dateDocument = "date_document"
        case dateExpiration = "date_expiration"
        case motifRefus = "motif_refus"
        case deposeLe = "depose_le"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        typeDocumentId = try c.decode(UUID.self, forKey: .typeDocumentId)
        fichierChemin = try c.decodeIfPresent(String.self, forKey: .fichierChemin) ?? ""
        nomFichier = try c.decodeIfPresent(String.self, forKey: .nomFichier) ?? "Pièce"
        dateDocument = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .dateDocument))
        dateExpiration = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .dateExpiration))
        statut = (try? c.decode(DocumentStatus.self, forKey: .statut)) ?? .enAttente
        motifRefus = try c.decodeIfPresent(String.self, forKey: .motifRefus)
        deposeLe = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .deposeLe))
    }

    /// Le déposant peut retirer une pièce tant qu'elle n'est pas validée.
    var isDeletable: Bool { statut != .valide }
}

/// État d'un type de pièce pour une personne, calculé comme sur le web.
nonisolated enum DocumentState: Equatable, Sendable {
    case missing
    case pending
    case valid
    case expiringSoon(days: Int)
    case expired
    case refused(reason: String?)

    /// Délai d'alerte avant expiration, comme le web.
    static let alertDays = 30

    init(document: MemberDocument?, today: Date = .now) {
        guard let document else { self = .missing; return }
        switch document.statut {
        case .refuse: self = .refused(reason: document.motifRefus)
        case .enAttente: self = .pending
        case .valide:
            guard let expiration = document.dateExpiration else { self = .valid; return }
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: expiration)).day ?? 0
            if days < 0 { self = .expired }
            else if days <= Self.alertDays { self = .expiringSoon(days: days) }
            else { self = .valid }
        }
    }

    /// Libellés du web (`MesPiecesPanel`).
    var label: String {
        switch self {
        case .missing: "À déposer"
        case .pending: "En cours de vérification"
        case .valid: "À jour"
        case .expiringSoon(let days): days == 0 ? "Expire aujourd'hui" : "Expire dans \(days) jour\(days > 1 ? "s" : "")"
        case .expired: "Expirée"
        case .refused: "Refusée"
        }
    }
}

// MARK: - Documents comptables

nonisolated enum AccountingDocumentKind: String, Sendable, Decodable {
    case recu, facture, avoir

    var label: String {
        switch self {
        case .recu: "Reçu"
        case .facture: "Facture"
        case .avoir: "Avoir"
        }
    }

    var symbolName: String {
        switch self {
        case .recu: "doc.text"
        case .facture: "doc.plaintext"
        case .avoir: "arrow.uturn.backward.circle"
        }
    }
}

nonisolated struct AccountingDocument: Identifiable, Hashable, Sendable, Decodable {
    let id: UUID
    let numero: String
    let type: AccountingDocumentKind
    let libelle: String
    let montantTtc: Double
    let emisLe: Date?
    let modePaiement: String?

    static let columns = "id, numero, type, libelle, montant_ttc, emis_le, mode_paiement"

    enum CodingKeys: String, CodingKey {
        case id, numero, type, libelle
        case montantTtc = "montant_ttc"
        case emisLe = "emis_le"
        case modePaiement = "mode_paiement"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        numero = try c.decode(String.self, forKey: .numero)
        type = (try? c.decode(AccountingDocumentKind.self, forKey: .type)) ?? .recu
        libelle = try c.decodeIfPresent(String.self, forKey: .libelle) ?? ""
        montantTtc = try c.decodeIfPresent(Double.self, forKey: .montantTtc) ?? 0
        emisLe = SupabaseDate.parse(try c.decodeIfPresent(String.self, forKey: .emisLe))
        modePaiement = try c.decodeIfPresent(String.self, forKey: .modePaiement)
    }
}
