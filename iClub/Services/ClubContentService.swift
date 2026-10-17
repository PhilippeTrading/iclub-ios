//
//  ClubContentService.swift
//  iClub
//
//  Annonces et activités publiées par le club.
//
//  Les deux lectures sont tolérantes à l'échec : l'accueil doit s'afficher même
//  si l'une d'elles ne répond pas. Une carte absente vaut mieux qu'un écran
//  bloqué sur une section secondaire.
//

import Foundation
import Supabase

enum ClubContentService {

    /// Annonces actives, de la plus récente à la plus ancienne.
    static func announcements(clubId: UUID, limit: Int) async -> [Announcement] {
        do {
            let rows: [Lenient<AnnouncementRow>] = try await Supa.client
                .from("annonces")
                .select(AnnouncementRow.columns)
                .eq("club_id", value: clubId.uuidString)
                // Une annonce retirée par l'admin ne doit plus apparaître.
                .eq("actif", value: true)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value

            return rows.compactValues().compactMap { $0.toDomain() }
        } catch {
            return []
        }
    }

    /// Cours et activités du club.
    ///
    /// La table décrit un **horaire hebdomadaire** — `jour` et `heure` sont du
    /// texte, il n'y a pas de date. Il n'y a donc pas de « prochains » à
    /// calculer : on prend les premiers dans l'ordre de création.
    static func activities(clubId: UUID, limit: Int) async -> [ClubActivity] {
        do {
            let rows: [Lenient<ActivityRow>] = try await Supa.client
                .from("activites")
                .select(ActivityRow.columns)
                .eq("club_id", value: clubId.uuidString)
                .order("created_at", ascending: true)
                .limit(limit)
                .execute()
                .value

            return rows.compactValues().compactMap { $0.toDomain() }
        } catch {
            return []
        }
    }
}
