//
//  MemberDocuments.swift
//  iClub
//
//  Pièces demandées par le club (`types_documents`, `documents_adherent`) et
//  documents comptables (`documents_comptables`). Même vocabulaire que le web.
//
//  Rôle
//    Lignes décodées des trois tables, et calcul de l'état d'une pièce
//    (à déposer, en vérification, à jour, bientôt expirée, expirée, refusée).
//
//  Place dans l'application
//    `MemberDocumentsService` les lit ; la section « Documents » du profil
//    (`DocumentsSection`) les affiche pour le membre et ses enfants, avec les
//    reçus et factures (`ProfileCards`).
//
//  Règles métier (migration `20261019130000_documents_adherent.sql`)
//    - Le club déclare lui-même les pièces qu'il exige, pour qui, et pour
//      combien de temps : aucune règle légale n'est codée.
//    - L'expiration se calcule à la lecture depuis `date_expiration` ; `statut`
//      ne porte que le circuit de vérification.
//    - Une pièce remplacée reste en historique (`remplace_par`) ; la pièce en
//      cours est celle qui n'a pas de remplaçante.
//
//  Droits et sécurité
//    - Pièces : le membre voit les siennes et celles de ses enfants
//      (`est_responsable_de`), l'administration celles du club ; personne
//      d'autre, pas même les encadrants. Seule l'administration valide.
//    - Documents comptables : le membre ne lit que les siens
//      (`profile_id = auth.uid()`) ; personne ne les modifie.
//

import Foundation

// MARK: - Types de pièces

/// Public visé par un type de pièce (`types_documents.concerne`).
nonisolated enum DocumentAudience: String, Sendable, Decodable {
    /// `tous` : tout le monde ; `mineurs` : les moins de 18 ans ; `majeurs` :
    /// les 18 ans et plus ; `competiteurs` : les compétiteurs (jamais filtré,
    /// faute de savoir qui joue en compétition).
    case tous, mineurs, majeurs, competiteurs
}

/// Ligne de `types_documents` : une pièce que le club demande.
nonisolated struct DocumentType: Identifiable, Hashable, Sendable, Decodable {
    /// `id`.
    let id: UUID
    /// `libelle` : nom de la pièce (« Licence », « Attestation de santé »…).
    let libelle: String
    /// `obligatoire` ; vrai à défaut, comme en base.
    let obligatoire: Bool
    /// `duree_validite_mois` : durée de validité (1 à 120 mois) ; `nil` pour une
    /// pièce qui n'expire pas.
    let dureeValiditeMois: Int?
    /// `concerne` : public visé ; `tous` si la valeur est inconnue.
    let concerne: DocumentAudience
    /// Pièce de santé : jamais d'aperçu hors de l'écran de dépôt.
    /// (`sensible`.)
    let sensible: Bool

    /// Colonnes demandées.
    static let columns = "id, libelle, obligatoire, duree_validite_mois, concerne, sensible"

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, libelle, obligatoire, concerne, sensible
        case dureeValiditeMois = "duree_validite_mois"
    }

    /// Décodage tolérant : identifiant et libellé obligatoires, valeurs par
    /// défaut pour le reste.
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
    ///
    /// - Parameter age: âge de la personne, `nil` s'il est inconnu.
    /// - Returns: `true` si la pièce est demandée à cette personne. Âge inconnu :
    ///   une pièce « mineurs » n'est pas demandée, une pièce « majeurs » l'est.
    func concerns(age: Int?) -> Bool {
        switch concerne {
        case .mineurs: if let age { age < 18 } else { false }
        case .majeurs: age.map { $0 >= 18 } ?? true
        case .tous, .competiteurs: true
        }
    }
}

// MARK: - Pièce déposée

/// Circuit de vérification (`documents_adherent.statut`).
nonisolated enum DocumentStatus: String, Sendable, Decodable {
    /// Déposée, pas encore vérifiée.
    case enAttente = "en_attente"
    /// Validée par le club.
    case valide
    /// Refusée par le club, avec un motif.
    case refuse
}

/// Ligne de `documents_adherent` : une pièce déposée.
nonisolated struct MemberDocument: Identifiable, Hashable, Sendable, Decodable {
    /// `id`.
    let id: UUID
    /// `profile_id` : personne concernée (le membre ou un enfant).
    let profileId: UUID
    /// `type_document_id`.
    let typeDocumentId: UUID
    /// `fichier_chemin` : chemin dans le compartiment privé
    /// `documents-adherents` (« club/profil/fichier »). Vide si absent.
    let fichierChemin: String
    /// `nom_fichier` : nom d'origine, « Pièce » à défaut.
    let nomFichier: String
    /// `date_document` : date figurant sur la pièce.
    let dateDocument: Date?
    /// `date_expiration` : calculée par la base au dépôt (date de la pièce plus
    /// la durée du type), modifiable par le club.
    let dateExpiration: Date?
    /// `statut`, `en_attente` si la valeur est inconnue.
    let statut: DocumentStatus
    /// `motif_refus`, pour une pièce refusée.
    let motifRefus: String?
    /// `depose_le` : date du dépôt.
    let deposeLe: Date?

    /// Colonnes demandées.
    static let columns = "id, profile_id, type_document_id, fichier_chemin, nom_fichier, date_document, date_expiration, statut, motif_refus, depose_le"

    /// Correspondance avec les colonnes SQL.
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

    /// Décodage tolérant : identifiants obligatoires, dates converties depuis
    /// le texte.
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
    /// (Même règle que la politique RLS `documents_adherent_suppression`.)
    var isDeletable: Bool { statut != .valide }
}

/// État d'un type de pièce pour une personne, calculé comme sur le web.
nonisolated enum DocumentState: Equatable, Sendable {
    /// Aucune pièce déposée.
    case missing
    /// Déposée, en attente de vérification.
    case pending
    /// Validée, et pas près d'expirer.
    case valid
    /// Validée, expire dans `days` jours (au plus `alertDays`).
    case expiringSoon(days: Int)
    /// Validée mais expirée.
    case expired
    /// Refusée, avec le motif du club.
    case refused(reason: String?)

    /// Délai d'alerte avant expiration, comme le web.
    /// (30 jours, `JOURS_ALERTE` dans `MesPiecesPanel`.)
    static let alertDays = 30

    /// - Parameters:
    ///   - document: pièce en cours de ce type, `nil` si aucune.
    ///   - today: jour de référence (aujourd'hui par défaut).
    init(document: MemberDocument?, today: Date = .now) {
        guard let document else { self = .missing; return }
        switch document.statut {
        case .refuse: self = .refused(reason: document.motifRefus)
        case .enAttente: self = .pending
        case .valide:
            // Sans date d'expiration, une pièce validée reste à jour.
            guard let expiration = document.dateExpiration else { self = .valid; return }
            let calendar = Calendar.current
            // Jours pleins entre aujourd'hui et l'expiration, comptés de minuit
            // à minuit (fuseau de l'appareil) ; 0 = expire aujourd'hui.
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

/// Nature d'un document comptable (`documents_comptables.type`).
nonisolated enum AccountingDocumentKind: String, Sendable, Decodable {
    /// `recu` : reçu (cotisation d'une association), numéroté « RC-… » ;
    /// `facture` : facture (club assujetti), numérotée « FA-… » ; `avoir` :
    /// annulation d'un reçu ou d'une facture, numérotée « AV-… ».
    case recu, facture, avoir

    /// Libellé affiché.
    var label: String {
        switch self {
        case .recu: "Reçu"
        case .facture: "Facture"
        case .avoir: "Avoir"
        }
    }

    /// Pictogramme SF Symbols.
    var symbolName: String {
        switch self {
        case .recu: "doc.text"
        case .facture: "doc.plaintext"
        case .avoir: "arrow.uturn.backward.circle"
        }
    }
}

/// Ligne de `documents_comptables` : reçu, facture ou avoir émis au membre.
nonisolated struct AccountingDocument: Identifiable, Hashable, Sendable, Decodable {
    /// `id`, utilisé aussi pour télécharger le PDF.
    let id: UUID
    /// `numero` : numéro unique dans le club (« FA-2026-0001 »…).
    let numero: String
    /// `type`, `recu` si la valeur est inconnue.
    let type: AccountingDocumentKind
    /// `libelle` : ce qui est facturé.
    let libelle: String
    /// `montant_ttc` (`numeric(10, 2)`, euros) ; 0 à défaut.
    let montantTtc: Double
    /// `emis_le` (`timestamptz`) : date d'émission.
    let emisLe: Date?
    /// `mode_paiement` : texte libre inscrit sur le document.
    let modePaiement: String?

    /// Colonnes demandées.
    static let columns = "id, numero, type, libelle, montant_ttc, emis_le, mode_paiement"

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case id, numero, type, libelle
        case montantTtc = "montant_ttc"
        case emisLe = "emis_le"
        case modePaiement = "mode_paiement"
    }

    /// Décodage tolérant : identifiant et numéro obligatoires.
    ///
    /// Attention : `montant_ttc` est une colonne `numeric` ; si PostgREST la
    /// rend en chaîne, le décodage en `Double` échoue et la ligne entière est
    /// refusée (contrairement à `CourtRow`, qui passe par `PostgresNumber`).
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
