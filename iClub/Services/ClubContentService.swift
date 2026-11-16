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
//  Place dans l'application
//    Appelé par l'accueil (`HomeStore.reload`, annonces et activités) et par
//    l'historique des notifications (`NotificationHistory`, annonces).
//
//  Tables lues
//    `annonces` et `activites`, filtrées sur le club. Lecture réservée aux
//    membres du club par la RLS (`annonces_select_club`,
//    `activites_select_club`). Aucune écriture.
//
//  Gestion des erreurs
//    Toute erreur (réseau, droits, décodage) donne une liste vide ; une ligne
//    illisible est écartée seule (`Lenient`).
//
//  Fil d'exécution
//    Acteur principal (isolement par défaut du projet) ; les appels réseau sont
//    asynchrones et ne bloquent pas l'interface. Aucun cache : chaque appel
//    relit la base.
//

import Foundation
import Supabase

/// Lectures des contenus éditoriaux du club.
enum ClubContentService {

    /// Annonces actives, de la plus récente à la plus ancienne.
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - limit: nombre maximal d'annonces rendues.
    /// - Returns: les annonces, ou une liste vide en cas d'échec.
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

            // Lignes illisibles et annonces sans titre écartées.
            return rows.compactValues().compactMap { $0.toDomain() }
        } catch {
            return []
        }
    }

    /// Cours et activités du club.
    ///
    /// La table décrit un **horaire hebdomadaire** : `jour` et `heure` sont du
    /// texte, il n'y a pas de date. Il n'y a donc pas de « prochains » à
    /// calculer : on prend les premiers dans l'ordre de création.
    ///
    /// Attention : aucun filtre sur `statut` (colonne ajoutée depuis par la
    /// migration `20261018100000_entrainement.sql`). Les activités en brouillon,
    /// proposées, terminées ou annulées sont donc lues et affichées sur l'accueil
    /// comme les autres, alors que l'onglet « Cours » ne montre que les
    /// activités en ligne (`ActivityService.loadPublished`).
    ///
    /// - Parameters:
    ///   - clubId: club du membre.
    ///   - limit: nombre maximal d'activités rendues.
    /// - Returns: les activités, ou une liste vide en cas d'échec.
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

            // Lignes illisibles et activités sans nom écartées.
            return rows.compactValues().compactMap { $0.toDomain() }
        } catch {
            return []
        }
    }
}
