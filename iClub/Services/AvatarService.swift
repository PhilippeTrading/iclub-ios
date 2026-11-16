//
//  AvatarService.swift
//  iClub
//
//  Envoi de la photo de profil dans le bucket `avatars`.
//
//  La convention est celle du web, reprise pour que les deux applications
//  lisent toujours la même image :
//
//    fichier             avatars/{profile_id}/avatar.png
//    profiles.avatar_url URL publique complète, suffixée de `?v=<millisecondes>`
//
//  (Le web nomme le fichier `avatar.` suivi de l'extension de l'image envoyée :
//  jpg, png, webp ou gif. L'app écrit toujours du PNG.)
//
//  Le chemin est fixe : on écrase le fichier plutôt que d'en empiler un nouveau
//  à chaque changement. C'est le paramètre de version dans l'URL qui fait
//  apparaître la nouvelle photo, pas un nom de fichier différent.
//
//  Les règles du bucket cloisonnent les dossiers : un membre n'écrit que sous
//  le sien. Il n'y a donc rien à vérifier côté app, mais rien à contourner non
//  plus si une écriture est refusée.
//
//  Place dans l'application
//    Écran du profil (changer, retirer la photo) et suppression du compte
//    (`AuthService.deleteMyAccount`, qui efface les fichiers avant tout).
//
//  Stockage et tables
//    - Compartiment `avatars` : lecture publique (`avatars_select_public`),
//      écriture et suppression limitées au dossier dont le nom est
//      l'identifiant de l'utilisateur connecté (`avatars_write_own_folder`,
//      migration `20260921113953_rankings_and_avatars.sql`).
//    - Table `profiles`, colonne `avatar_url` (RLS : sa propre ligne).
//
//  Points d'attention
//    Un fichier `avatar.jpg` déposé depuis le web reste dans le dossier quand
//    l'app envoie `avatar.png` : seule l'URL enregistrée décide de la photo
//    affichée. Le retrait de la photo, lui, vide tout le dossier.
//

import Foundation
import Supabase
import UIKit

/// Erreurs de la photo de profil, avec leur message affichable.
enum AvatarError: LocalizedError {
    /// Les données choisies ne forment pas une image lisible.
    case unreadableImage
    /// Le fichier est parti, mais `profiles.avatar_url` n'a pas été modifié
    /// (aucune ligne touchée : RLS ou profil introuvable).
    case updateRejected

    /// Message montré dans le profil.
    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "Cette image n'a pas pu être lue. Essaie une autre photo."
        case .updateRejected:
            "La photo a été envoyée mais n'a pas pu être enregistrée sur ton profil."
        }
    }
}

/// Photo de profil : envoi, retrait, nettoyage.
enum AvatarService {

    /// Compartiment de stockage Supabase des photos.
    private static let bucket = "avatars"
    /// Nom de fichier fixe, écrasé à chaque changement.
    private static let fileName = "avatar.png"

    /// Côté le plus long de l'image envoyée. 512 px suffit largement pour une
    /// vignette ronde de 60 pt, même sur un écran à 3×, et évite d'envoyer
    /// plusieurs mégaoctets depuis une photo d'iPhone.
    private static let maxDimension: CGFloat = 512

    /// Chemin du fichier dans le compartiment.
    ///
    /// L'identifiant est mis en minuscules : `uuidString` est en majuscules,
    /// alors que la règle du compartiment compare le dossier à
    /// `auth.uid()::text`, écrit en minuscules par PostgreSQL.
    ///
    /// - Parameter profileId: profil du membre.
    /// - Returns: « {profile_id}/avatar.png ».
    static func storagePath(for profileId: UUID) -> String {
        "\(profileId.uuidString.lowercased())/\(fileName)"
    }

    /// Recadre, envoie, puis enregistre l'URL sur le profil.
    ///
    /// - Parameters:
    ///   - profileId: profil du membre connecté (seul son dossier est
    ///     accessible en écriture).
    ///   - imageData: image choisie (photothèque ou appareil photo).
    /// - Returns: l'URL versionnée effectivement écrite en base.
    /// - Throws: `AvatarError.unreadableImage`, `AvatarError.updateRejected`, ou
    ///   l'erreur du stockage ou de la requête.
    static func updatePhoto(profileId: UUID, imageData: Data) async throws -> URL {
        guard let png = squarePNG(from: imageData) else {
            throw AvatarError.unreadableImage
        }

        let path = storagePath(for: profileId)
        let storage = Supa.client.storage.from(bucket)

        // `upsert` : le fichier existant est remplacé.
        try await storage.upload(
            path,
            data: png,
            options: FileOptions(contentType: "image/png", upsert: true)
        )

        // URL publique (le compartiment est en lecture publique), versionnée.
        let url = versioned(try storage.getPublicURL(path: path))

        // `.select()` puis contrôle du résultat : PostgREST répond `200` sans
        // corps même quand aucune ligne n'est touchée. Sans cela, une écriture
        // refusée passerait pour un succès et l'ancienne photo resterait.
        let updated: [ProfileRow] = try await Supa.client
            .from("profiles")
            .update(AvatarUpdate(avatarUrl: url.absoluteString))
            .eq("id", value: profileId.uuidString)
            .select(ProfileRow.allColumns)
            .execute()
            .value

        guard !updated.isEmpty else {
            throw AvatarError.updateRejected
        }

        return url
    }

    // MARK: - Retrait

    /// « Retirer la photo » : les fichiers du dossier d'abord, puis
    /// `avatar_url` à `null` ; les initiales reprennent leur place.
    ///
    /// - Parameter profileId: profil du membre connecté.
    /// - Throws: `AvatarError.updateRejected` si le profil n'a pas été modifié,
    ///   ou l'erreur de la requête. L'échec de l'effacement des fichiers, lui,
    ///   est ignoré.
    static func removePhoto(profileId: UUID) async throws {
        await deleteAllFiles(profileId: profileId)

        let updated: [ProfileRow] = try await Supa.client
            .from("profiles")
            .update(AvatarRemoval())
            .eq("id", value: profileId.uuidString)
            .select(ProfileRow.allColumns)
            .execute()
            .value

        guard !updated.isEmpty else {
            throw AvatarError.updateRejected
        }
    }

    /// Charge utile `{ "avatar_url": null }`. Écrite à la main : l'encodeur
    /// synthétisé omettrait une clé nulle, et la colonne ne serait pas vidée.
    private nonisolated struct AvatarRemoval: Encodable, Sendable {
        /// Seule colonne écrite.
        enum CodingKeys: String, CodingKey { case avatarUrl = "avatar_url" }
        /// Écrit explicitement `null`.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeNil(forKey: .avatarUrl)
        }
    }

    // MARK: - Suppression

    /// Efface tous les fichiers du dossier `avatars/{profile_id}/`, quelle que
    /// soit leur extension : le web écrit du `.jpg` (ou l'extension de l'image
    /// envoyée), iOS du `.png`.
    ///
    /// À appeler **avant** `delete_my_account()` : une fois `avatar_url` vidé
    /// par la fonction, plus rien ne pointerait vers ces fichiers.
    ///
    /// Ne lève jamais : un fichier orphelin est un désagrément, un compte non
    /// supprimé est un problème. Cette étape ne doit pas bloquer la suivante.
    ///
    /// - Parameter profileId: profil du membre connecté.
    static func deleteAllFiles(profileId: UUID) async {
        let folder = profileId.uuidString.lowercased()
        let storage = Supa.client.storage.from(bucket)

        // Liste du dossier (première page du SDK, largement suffisante pour un
        // ou deux fichiers), puis suppression en une seule requête.
        guard let files = try? await storage.list(path: folder), !files.isEmpty else { return }
        let paths = files.map { "\(folder)/\($0.name)" }
        _ = try? await storage.remove(paths: paths)
    }

    // MARK: - URL

    /// Ajoute `?v=<millisecondes>`. Sans ce paramètre l'image resterait celle du
    /// cache (celui du CDN comme celui d'`AsyncImage`, qui indexe par URL) et
    /// la nouvelle photo n'apparaîtrait pas.
    ///
    /// - Parameter url: URL publique du fichier.
    /// - Returns: la même URL avec un seul paramètre `v` (millisecondes depuis
    ///   1970) ; l'URL d'origine si elle ne peut pas être décomposée.
    private static func versioned(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let stamp = String(Int(Date.now.timeIntervalSince1970 * 1000))
        components?.queryItems = [URLQueryItem(name: "v", value: stamp)]
        return components?.url ?? url
    }

    // MARK: - Image

    /// Recadre au centre en carré, redimensionne, et encode en PNG.
    ///
    /// Le dessin passe par `UIImage.draw(in:)`, qui applique l'orientation EXIF :
    /// une photo prise en paysage n'arrive donc pas couchée.
    ///
    /// Volontairement non privée : transformation pure, donc vérifiable seule.
    ///
    /// - Parameter data: image d'origine, dans un format lisible par `UIImage`.
    /// - Returns: PNG carré de 512 × 512 pixels, opaque (une zone transparente
    ///   de l'image d'origine n'est pas conservée), ou `nil` si l'image est
    ///   illisible ou vide.
    static func squarePNG(from data: Data) -> Data? {
        guard let image = UIImage(data: data),
              image.size.width > 0,
              image.size.height > 0
        else { return nil }

        let target = CGSize(width: maxDimension, height: maxDimension)

        let format = UIGraphicsImageRendererFormat.default()
        // Échelle 1 : la cible est déjà exprimée en pixels.
        format.scale = 1
        format.opaque = true

        let output = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // Remplissage : le côté le plus court épouse le carré, l'autre
            // déborde symétriquement et se fait rogner.
            let aspect = image.size.width / image.size.height
            var rect = CGRect(origin: .zero, size: target)

            if aspect > 1 {
                // Paysage : largeur agrandie, centrée horizontalement.
                rect.size.width = target.height * aspect
                rect.origin.x = (target.width - rect.size.width) / 2
            } else if aspect < 1 {
                // Portrait : hauteur agrandie, centrée verticalement.
                rect.size.height = target.width / aspect
                rect.origin.y = (target.height - rect.size.height) / 2
            }

            image.draw(in: rect)
        }

        return output.pngData()
    }
}
