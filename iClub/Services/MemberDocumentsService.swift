//
//  MemberDocumentsService.swift
//  iClub
//
//  Pièces, reçus et famille, côté membre. Tout passe par les règles d'accès de
//  la base : le membre n'écrit que dans son dossier et ceux de ses enfants, ne
//  lit que ses propres reçus.
//
//  Place dans l'application
//    Section « Documents » du profil (`DocumentsSection`, `ProfileExtrasStore`) :
//    pièces demandées par le club, dépôt depuis l'appareil photo, la
//    photothèque ou les fichiers, reçus et factures en PDF (`ProfileCards`).
//    Section « Famille » (`FamilySection`) : création et retrait d'un enfant.
//
//  Tables, fonctions SQL et stockage
//    - Tables `types_documents` (lisible par les membres du club),
//      `documents_adherent` (soi, ses enfants, l'administration),
//      `documents_comptables` (soi seulement, `profile_id = auth.uid()`),
//      `clubs` (lecture publique, pour le sous-domaine).
//    - Fonctions `deposer_piece` (migration `20261023110000_pieces_depuis_mobile.sql`),
//      `creer_compte_enfant` et `retirer_lien_famille`
//      (`20261018160000_comptes_famille.sql`).
//    - Compartiment privé `documents-adherents`, chemin « club/profil/fichier » :
//      dépôt, lecture et suppression permis pour ses propres fichiers et ceux
//      de ses enfants (`pieces_depot_mobile`, `pieces_lecture_mobile`,
//      `pieces_suppression_mobile`).
//    - Route du site web `GET /api/documents/{id}` (sous-domaine du club), qui
//      produit le PDF d'un reçu ou d'une facture.
//
//  Données sensibles
//    Une attestation de santé est une donnée de santé au sens du RGPD : le
//    fichier est seulement stocké, jamais lu ni analysé par l'app ou la base.
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet), appels asynchrones.
//    Aucun cache ; le PDF téléchargé est écrit dans le dossier temporaire.
//

import Foundation
import Supabase
import UniformTypeIdentifiers

/// Pièces du membre, documents comptables et comptes d'enfants.
enum MemberDocumentsService {

    /// Compartiment privé des pièces déposées.
    static let piecesBucket = "documents-adherents"
    /// Taille maximale d'une pièce : 10 Mo (10 × 1 024 × 1 024 octets), la
    /// même limite que celle vérifiée par `deposer_piece`.
    static let maxPieceBytes = 10 * 1024 * 1024

    // MARK: - Pièces

    /// Pièces que le club demande, dans l'ordre choisi par l'administration.
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: types actifs triés par `ordre`.
    /// - Throws: l'erreur brute de la requête ou du décodage (tableau décodé
    ///   sans `Lenient` : une ligne illisible fait échouer la liste).
    static func documentTypes(clubId: UUID) async throws -> [DocumentType] {
        try await Supa.client
            .from("types_documents")
            .select(DocumentType.columns)
            .eq("club_id", value: clubId.uuidString)
            .eq("actif", value: true)
            .order("ordre")
            .execute()
            .value
    }

    /// Pièces en cours (celles qui n'ont pas été remplacées) de ces personnes.
    ///
    /// - Parameter profileIds: le membre et ses enfants ; vide, aucune requête.
    /// - Returns: pièces sans remplaçante (`remplace_par` nul), les plus
    ///   récentes d'abord. La RLS écarte tout profil qui n'est ni soi ni un
    ///   enfant dont on est responsable.
    /// - Throws: l'erreur brute de la requête ou du décodage.
    static func currentDocuments(profileIds: [UUID]) async throws -> [MemberDocument] {
        guard !profileIds.isEmpty else { return [] }
        return try await Supa.client
            .from("documents_adherent")
            .select(MemberDocument.columns)
            .in("profile_id", values: profileIds.map(\.uuidString))
            .is("remplace_par", value: nil)
            .order("depose_le", ascending: false)
            .execute()
            .value
    }

    /// Envoie le fichier dans le compartiment privé, puis l'enregistre par
    /// `deposer_piece`, qui calcule l'expiration et remplace l'ancienne pièce.
    /// Le fichier est retiré si l'enregistrement échoue : pas de fichier orphelin.
    ///
    /// `deposer_piece` revérifie tout côté base : droit sur la personne (soi ou
    /// un enfant), type actif du club, chemin attendu, taille (1 octet à
    /// 10 Mo), format (PDF, JPEG, PNG, HEIC, HEIF). La pièce part « en
    /// attente » ; l'expiration vaut la date de la pièce (ou le jour du dépôt)
    /// plus la durée de validité du type.
    ///
    /// - Parameters:
    ///   - data: contenu du fichier.
    ///   - fileName: nom d'origine, conservé pour l'affichage.
    ///   - mimeType: type MIME (voir `mimeType(for:)`).
    ///   - type: pièce demandée.
    ///   - profileId: personne concernée (soi ou un enfant).
    ///   - clubId: club du membre, premier dossier du chemin.
    ///   - documentDate: date figurant sur la pièce, `nil` si non saisie.
    /// - Throws: `ActivityServiceError.refused` (fichier trop lourd, envoi
    ///   impossible, refus rédigé de la base) ou `.failed`.
    static func deposit(
        data: Data,
        fileName: String,
        mimeType: String,
        type: DocumentType,
        profileId: UUID,
        clubId: UUID,
        documentDate: Date?
    ) async throws {
        // Contrôle local avant tout envoi : épargne un transfert voué au refus.
        guard data.count <= maxPieceBytes else {
            throw ActivityServiceError.refused("Le fichier dépasse 10 Mo.")
        }

        let ext = fileExtension(for: mimeType)
        // Identifiants en minuscules : la base compare le chemin à `club::text`.
        // Nom de fichier tiré au hasard : deux dépôts ne s'écrasent jamais.
        let path = "\(clubId.uuidString.lowercased())/\(profileId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(ext)"
        let storage = Supa.client.storage.from(piecesBucket)

        // 1. Le fichier. Un refus des règles du compartiment arrive ici aussi,
        //    sous le même message.
        do {
            _ = try await storage.upload(path, data: data, options: FileOptions(contentType: mimeType, upsert: false))
        } catch {
            throw ActivityServiceError.refused("Le fichier n'a pas pu être envoyé. Vérifiez votre connexion et réessayez.")
        }

        // 2. L'enregistrement. La fonction rend l'identifiant de la pièce,
        //    inutilisé ici.
        do {
            let _: UUID = try await Supa.client
                .rpc("deposer_piece", params: DepositParams(
                    typeDocumentId: type.id,
                    profileId: profileId,
                    chemin: path,
                    nomFichier: fileName,
                    tailleOctets: data.count,
                    typeMime: mimeType,
                    dateDocument: documentDate.map(SupabaseDate.day(from:))
                ))
                .execute()
                .value
        } catch {
            // Rattrapage : le fichier sans ligne serait un orphelin, illisible
            // par le club. Un échec de ce retrait est ignoré.
            _ = try? await storage.remove(paths: [path])
            throw ActivityServiceError.from(error)
        }
    }

    /// Une pièce en attente ou refusée : la ligne d'abord, le fichier ensuite.
    ///
    /// Si la pièce supprimée en remplaçait une autre, l'ancienne redevient la
    /// pièce en cours (`remplace_par` repasse à `null` par la clé étrangère
    /// `on delete set null`).
    ///
    /// - Parameter document: pièce à retirer.
    /// - Throws: `ActivityServiceError.refused` si la base n'a rien supprimé
    ///   (pièce validée entre-temps, ou hors de ses droits), ou une erreur
    ///   traduite par `ActivityServiceError.from`.
    static func delete(_ document: MemberDocument) async throws {
        do {
            // `.select("id")` : une suppression refusée par la RLS
            // (`documents_adherent_suppression`, pièce déjà validée) ne lève pas
            // d'erreur, elle rend une liste vide.
            let rows: [IdRow] = try await Supa.client
                .from("documents_adherent")
                .delete()
                .eq("id", value: document.id.uuidString)
                .select("id")
                .execute()
                .value
            guard !rows.isEmpty else {
                throw ActivityServiceError.refused("Cette pièce ne peut plus être supprimée : elle a déjà été validée par le club.")
            }
        } catch {
            throw ActivityServiceError.from(error)
        }
        // Le fichier ensuite ; un échec laisse un fichier orphelin, sans gêne
        // pour le membre.
        if !document.fichierChemin.isEmpty {
            _ = try? await Supa.client.storage.from(piecesBucket).remove(paths: [document.fichierChemin])
        }
    }

    /// Type MIME d'un fichier choisi, parmi les formats acceptés par la base.
    ///
    /// - Parameter type: type uniforme du fichier.
    /// - Returns: le type MIME, ou `nil` pour un format refusé.
    static func mimeType(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "application/pdf" }
        if type.conforms(to: .heic) { return "image/heic" }
        if type.conforms(to: .heif) { return "image/heif" }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        return nil
    }

    /// - Parameter mimeType: type MIME accepté.
    /// - Returns: extension du fichier stocké ; « jpg » pour tout autre type.
    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "application/pdf": "pdf"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        default: "jpg"
        }
    }

    // MARK: - Reçus et factures

    /// Reçus, factures et avoirs émis au membre.
    ///
    /// - Parameter profileId: profil du membre. La RLS
    ///   (`profile_id = auth.uid()`) ne rend rien pour un autre profil, enfant
    ///   compris.
    /// - Returns: documents du plus récent au plus ancien.
    /// - Throws: l'erreur brute de la requête ou du décodage.
    static func accountingDocuments(profileId: UUID) async throws -> [AccountingDocument] {
        try await Supa.client
            .from("documents_comptables")
            .select(AccountingDocument.columns)
            .eq("profile_id", value: profileId.uuidString)
            .order("emis_le", ascending: false)
            .execute()
            .value
    }

    /// Le PDF, servi par le site du club avec le jeton de la session. Écrit dans
    /// un fichier temporaire pour l'aperçu et le partage.
    ///
    /// La route web reconnaît le jeton d'accès Supabase passé en `Bearer`, le
    /// vérifie et ne sert que les documents de ce profil.
    ///
    /// - Parameters:
    ///   - document: document à télécharger.
    ///   - clubSlug: sous-domaine du club (`clubs.slug`).
    /// - Returns: URL du fichier temporaire, nommé d'après le numéro du
    ///   document (les « / » remplacés par des tirets), extension `.pdf`.
    /// - Throws: `ActivityServiceError.failed` (adresse invalide),
    ///   `ActivityServiceError.refused` (réponse qui n'est pas un PDF), l'erreur
    ///   de session, du réseau ou de l'écriture du fichier.
    static func downloadPDF(_ document: AccountingDocument, clubSlug: String) async throws -> URL {
        guard let url = URL(string: "https://\(clubSlug).iclubapp.fr/api/documents/\(document.id.uuidString.lowercased())") else {
            throw ActivityServiceError.failed
        }
        // Session courante (rafraîchie par le SDK si son jeton a expiré).
        let session = try await Supa.client.auth.session

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        // Une redirection vers la connexion arrive en 200 avec une page HTML :
        // seul un vrai PDF compte.
        let isPDF = http?.statusCode == 200
            && (http?.value(forHTTPHeaderField: "Content-Type")?.contains("application/pdf") ?? false)
        guard isPDF else {
            throw ActivityServiceError.refused("Le téléchargement n'est pas encore disponible. Vous pouvez demander ce document au club.")
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(document.numero.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension("pdf")
        try data.write(to: file, options: .atomic)
        return file
    }

    // MARK: - Club

    /// Ligne de `clubs` réduite au sous-domaine.
    private nonisolated struct SlugRow: Decodable, Sendable { let slug: String }

    /// Sous-domaine du club (`demo` → demo.iclubapp.fr).
    ///
    /// - Parameter clubId: club du membre.
    /// - Returns: `clubs.slug`, ou `nil` en cas d'échec.
    static func clubSlug(clubId: UUID) async -> String? {
        let rows: [SlugRow]? = try? await Supa.client
            .from("clubs")
            .select("slug")
            .eq("id", value: clubId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows?.first?.slug
    }

    // MARK: - Famille

    /// Crée le compte d'un enfant, rattaché au membre connecté.
    ///
    /// La fonction `creer_compte_enfant` crée un profil sans connexion
    /// (`compte_gere`, aucune adresse, date du consentement parental
    /// conservée), son appartenance au club (rôle `junior`) et le lien de
    /// famille. Elle refuse un doublon (même prénom, nom et date de naissance),
    /// une date future, un appelant qui n'est pas adhérent du club ou qui est
    /// lui-même un compte géré.
    ///
    /// - Parameters:
    ///   - clubId: club du parent.
    ///   - prenom: prénom de l'enfant (espaces de bord retirés).
    ///   - nom: nom de l'enfant (espaces de bord retirés).
    ///   - birthDate: date de naissance.
    ///   - sexe: sexe, `nil` si non renseigné.
    /// - Throws: `ActivityServiceError` (refus rédigé de la base, échec).
    static func createChild(clubId: UUID, prenom: String, nom: String, birthDate: Date, sexe: Sexe?) async throws {
        do {
            // La fonction rend l'identifiant du profil créé, inutilisé ici.
            let _: UUID = try await Supa.client
                .rpc("creer_compte_enfant", params: ChildParams(
                    clubId: clubId,
                    prenom: prenom.trimmingCharacters(in: .whitespaces),
                    nom: nom.trimmingCharacters(in: .whitespaces),
                    dateNaissance: SupabaseDate.day(from: birthDate),
                    sexe: sexe?.rawValue
                ))
                .execute()
                .value
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    /// Retire le lien, pas le compte de l'enfant.
    ///
    /// L'enfant garde son profil, son historique et son appartenance au club :
    /// seul le club peut le faire disparaître.
    ///
    /// - Parameter childId: profil de l'enfant.
    /// - Throws: `ActivityServiceError` (« Lien introuvable », échec).
    static func removeChild(_ childId: UUID) async throws {
        do {
            try await Supa.client
                .rpc("retirer_lien_famille", params: ChildIdParam(childId: childId))
                .execute()
        } catch {
            throw ActivityServiceError.from(error)
        }
    }

    // MARK: - Paramètres

    /// Ligne rendue par la suppression (`.select("id")`).
    private nonisolated struct IdRow: Decodable, Sendable { let id: UUID }

    /// Paramètres de `deposer_piece`.
    private nonisolated struct DepositParams: Encodable, Sendable {
        /// `p_type_document_id`.
        let typeDocumentId: UUID
        /// `p_profile_id` : personne concernée.
        let profileId: UUID
        /// `p_chemin` : chemin du fichier dans le compartiment.
        let chemin: String
        /// `p_nom_fichier` : nom d'origine.
        let nomFichier: String
        /// `p_taille_octets`.
        let tailleOctets: Int
        /// `p_type_mime`.
        let typeMime: String
        /// `p_date_document` (« AAAA-MM-JJ »), `nil` si non saisie.
        let dateDocument: String?

        /// Noms des paramètres SQL.
        enum CodingKeys: String, CodingKey {
            case typeDocumentId = "p_type_document_id"
            case profileId = "p_profile_id"
            case chemin = "p_chemin"
            case nomFichier = "p_nom_fichier"
            case tailleOctets = "p_taille_octets"
            case typeMime = "p_type_mime"
            case dateDocument = "p_date_document"
        }

        /// Toutes les clés, `null` compris : l'encodeur synthétisé omettrait
        /// une date absente.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(typeDocumentId, forKey: .typeDocumentId)
            try c.encode(profileId, forKey: .profileId)
            try c.encode(chemin, forKey: .chemin)
            try c.encode(nomFichier, forKey: .nomFichier)
            try c.encode(tailleOctets, forKey: .tailleOctets)
            try c.encode(typeMime, forKey: .typeMime)
            try c.encode(dateDocument, forKey: .dateDocument)
        }
    }

    /// Paramètres de `creer_compte_enfant`.
    private nonisolated struct ChildParams: Encodable, Sendable {
        /// `p_club_id`.
        let clubId: UUID
        /// `p_prenom`.
        let prenom: String
        /// `p_nom`.
        let nom: String
        /// `p_date_naissance` (« AAAA-MM-JJ »).
        let dateNaissance: String
        /// `p_sexe` : « H », « F » ou `null`.
        let sexe: String?

        /// Noms des paramètres SQL ; `p_relation` n'a pas de propriété, sa
        /// valeur est fixe.
        enum CodingKeys: String, CodingKey {
            case clubId = "p_club_id"
            case prenom = "p_prenom"
            case nom = "p_nom"
            case dateNaissance = "p_date_naissance"
            case sexe = "p_sexe"
            case relation = "p_relation"
        }

        /// Toutes les clés, `null` compris, et la relation « parent » (les
        /// autres valeurs admises par la base, « tuteur » et « conjoint », ne
        /// sont pas proposées par l'app).
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(clubId, forKey: .clubId)
            try c.encode(prenom, forKey: .prenom)
            try c.encode(nom, forKey: .nom)
            try c.encode(dateNaissance, forKey: .dateNaissance)
            try c.encode(sexe, forKey: .sexe)
            try c.encode("parent", forKey: .relation)
        }
    }

    /// Paramètre de `retirer_lien_famille`.
    private nonisolated struct ChildIdParam: Encodable, Sendable {
        /// `p_enfant_profile_id`.
        let childId: UUID
        /// Nom du paramètre SQL.
        enum CodingKeys: String, CodingKey { case childId = "p_enfant_profile_id" }
    }
}
