//
//  MemberDocumentsService.swift
//  iClub
//
//  Pièces, reçus et famille, côté membre. Tout passe par les règles d'accès de
//  la base : le membre n'écrit que dans son dossier et ceux de ses enfants, ne
//  lit que ses propres reçus.
//

import Foundation
import Supabase
import UniformTypeIdentifiers

enum MemberDocumentsService {

    static let piecesBucket = "documents-adherents"
    static let maxPieceBytes = 10 * 1024 * 1024

    // MARK: - Pièces

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
    static func deposit(
        data: Data,
        fileName: String,
        mimeType: String,
        type: DocumentType,
        profileId: UUID,
        clubId: UUID,
        documentDate: Date?
    ) async throws {
        guard data.count <= maxPieceBytes else {
            throw ActivityServiceError.refused("Le fichier dépasse 10 Mo.")
        }

        let ext = fileExtension(for: mimeType)
        // Identifiants en minuscules : la base compare le chemin à `club::text`.
        let path = "\(clubId.uuidString.lowercased())/\(profileId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(ext)"
        let storage = Supa.client.storage.from(piecesBucket)

        do {
            _ = try await storage.upload(path, data: data, options: FileOptions(contentType: mimeType, upsert: false))
        } catch {
            throw ActivityServiceError.refused("Le fichier n'a pas pu être envoyé. Vérifiez votre connexion et réessayez.")
        }

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
            _ = try? await storage.remove(paths: [path])
            throw ActivityServiceError.from(error)
        }
    }

    /// Une pièce en attente ou refusée : la ligne d'abord, le fichier ensuite.
    static func delete(_ document: MemberDocument) async throws {
        do {
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
        if !document.fichierChemin.isEmpty {
            _ = try? await Supa.client.storage.from(piecesBucket).remove(paths: [document.fichierChemin])
        }
    }

    static func mimeType(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "application/pdf" }
        if type.conforms(to: .heic) { return "image/heic" }
        if type.conforms(to: .heif) { return "image/heif" }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        return nil
    }

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
    static func downloadPDF(_ document: AccountingDocument, clubSlug: String) async throws -> URL {
        guard let url = URL(string: "https://\(clubSlug).iclubapp.fr/api/documents/\(document.id.uuidString.lowercased())") else {
            throw ActivityServiceError.failed
        }
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

    private nonisolated struct SlugRow: Decodable, Sendable { let slug: String }

    /// Sous-domaine du club (`demo` → demo.iclubapp.fr).
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

    static func createChild(clubId: UUID, prenom: String, nom: String, birthDate: Date, sexe: Sexe?) async throws {
        do {
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

    private nonisolated struct IdRow: Decodable, Sendable { let id: UUID }

    private nonisolated struct DepositParams: Encodable, Sendable {
        let typeDocumentId: UUID
        let profileId: UUID
        let chemin: String
        let nomFichier: String
        let tailleOctets: Int
        let typeMime: String
        let dateDocument: String?

        enum CodingKeys: String, CodingKey {
            case typeDocumentId = "p_type_document_id"
            case profileId = "p_profile_id"
            case chemin = "p_chemin"
            case nomFichier = "p_nom_fichier"
            case tailleOctets = "p_taille_octets"
            case typeMime = "p_type_mime"
            case dateDocument = "p_date_document"
        }

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

    private nonisolated struct ChildParams: Encodable, Sendable {
        let clubId: UUID
        let prenom: String
        let nom: String
        let dateNaissance: String
        let sexe: String?

        enum CodingKeys: String, CodingKey {
            case clubId = "p_club_id"
            case prenom = "p_prenom"
            case nom = "p_nom"
            case dateNaissance = "p_date_naissance"
            case sexe = "p_sexe"
            case relation = "p_relation"
        }

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

    private nonisolated struct ChildIdParam: Encodable, Sendable {
        let childId: UUID
        enum CodingKeys: String, CodingKey { case childId = "p_enfant_profile_id" }
    }
}
