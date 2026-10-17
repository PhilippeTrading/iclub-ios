//
//  AvatarService.swift
//  iClub
//
//  Envoi de la photo de profil dans le bucket `avatars`.
//
//  La convention est celle du web, reprise à l'identique pour que les deux
//  applications lisent toujours la même image :
//
//    fichier             avatars/{profile_id}/avatar.png
//    profiles.avatar_url URL publique complète, suffixée de `?v=<millisecondes>`
//
//  Le chemin est fixe : on écrase le fichier plutôt que d'en empiler un nouveau
//  à chaque changement. C'est le paramètre de version dans l'URL qui fait
//  apparaître la nouvelle photo, pas un nom de fichier différent.
//
//  Les règles du bucket cloisonnent les dossiers : un membre n'écrit que sous
//  le sien. Il n'y a donc rien à vérifier côté app, mais rien à contourner non
//  plus si une écriture est refusée.
//

import Foundation
import Supabase
import UIKit

enum AvatarError: LocalizedError {
    case unreadableImage
    case updateRejected

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "Cette image n'a pas pu être lue. Essaie une autre photo."
        case .updateRejected:
            "La photo a été envoyée mais n'a pas pu être enregistrée sur ton profil."
        }
    }
}

enum AvatarService {

    private static let bucket = "avatars"
    private static let fileName = "avatar.png"

    /// Côté le plus long de l'image envoyée. 512 px suffit largement pour une
    /// vignette ronde de 60 pt, même sur un écran à 3×, et évite d'envoyer
    /// plusieurs mégaoctets depuis une photo d'iPhone.
    private static let maxDimension: CGFloat = 512

    static func storagePath(for profileId: UUID) -> String {
        "\(profileId.uuidString.lowercased())/\(fileName)"
    }

    /// Recadre, envoie, puis enregistre l'URL sur le profil.
    ///
    /// - Returns: l'URL versionnée effectivement écrite en base.
    static func updatePhoto(profileId: UUID, imageData: Data) async throws -> URL {
        guard let png = squarePNG(from: imageData) else {
            throw AvatarError.unreadableImage
        }

        let path = storagePath(for: profileId)
        let storage = Supa.client.storage.from(bucket)

        try await storage.upload(
            path,
            data: png,
            options: FileOptions(contentType: "image/png", upsert: true)
        )

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

    // MARK: - Suppression

    /// Efface tous les fichiers du dossier `avatars/{profile_id}/`, quelle que
    /// soit leur extension — le web écrit du `.jpg`, iOS du `.png`.
    ///
    /// À appeler **avant** `delete_my_account()` : une fois `avatar_url` vidé
    /// par la fonction, plus rien ne pointerait vers ces fichiers.
    ///
    /// Ne lève jamais : un fichier orphelin est un désagrément, un compte non
    /// supprimé est un problème. Cette étape ne doit pas bloquer la suivante.
    static func deleteAllFiles(profileId: UUID) async {
        let folder = profileId.uuidString.lowercased()
        let storage = Supa.client.storage.from(bucket)

        guard let files = try? await storage.list(path: folder), !files.isEmpty else { return }
        let paths = files.map { "\(folder)/\($0.name)" }
        _ = try? await storage.remove(paths: paths)
    }

    // MARK: - URL

    /// Ajoute `?v=<millisecondes>`. Sans ce paramètre l'image resterait celle du
    /// cache — celui du CDN comme celui d'`AsyncImage`, qui indexe par URL — et
    /// la nouvelle photo n'apparaîtrait pas.
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
                rect.size.width = target.height * aspect
                rect.origin.x = (target.width - rect.size.width) / 2
            } else if aspect < 1 {
                rect.size.height = target.width / aspect
                rect.origin.y = (target.height - rect.size.height) / 2
            }

            image.draw(in: rect)
        }

        return output.pngData()
    }
}
