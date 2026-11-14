//
//  SlotOverride.swift
//  iClub
//
//  Blocages posés par l'admin depuis le back-office web. Un override rend un
//  créneau indisponible au même titre qu'une réservation, et c'est lui qui
//  fournit la raison affichée en gris sur l'écran de choix du terrain.
//
//  Rôle
//    Ligne décodée de la table `slot_overrides` et traduction de sa colonne
//    `etat` en libellé français.
//
//  Place dans l'application
//    Lue par `PlanningService.loadSlotOverrides` (blocages du jour), consommée
//    par `AvailabilityEngine`. Des blocages sont aussi créés par la base
//    elle-même : la fonction `creer_activite` en pose un (état `cours`) pour
//    chaque séance d'un cours en ligne, et `annuler_seance` le retire.
//
//  Droits et sécurité
//    Lecture par les membres du club (RLS `slot_overrides_select_club`),
//    écriture réservée à l'administration (`slot_overrides_write_admin`).
//

import Foundation

/// Valeurs de la colonne `slot_overrides.etat`. Un état inconnu de l'app ne doit
/// pas produire une case vide : le repli est géré par `SlotOverrideRow.reason`.
/// La liste reprend la contrainte `check` de la colonne.
nonisolated enum SlotOverrideState: String, Sendable {
    /// Entretien du terrain.
    case maintenance
    /// Terrain fermé.
    case ferme
    /// Cours collectif ou individuel.
    case cours
    /// Stage.
    case stage
    /// Tournoi.
    case tournoi
    /// Compétition.
    case competition
    /// Événement du club.
    case evenement
    /// Créneau réservé aux adhérents.
    case adherents
    /// Complet.
    case complet
    /// Indisponible, sans précision.
    case indisponible

    /// Libellé affiché en gris dans la case du terrain.
    var label: String {
        switch self {
        case .maintenance: "Entretien"
        case .ferme: "Fermé"
        case .cours: "Cours"
        case .stage: "Stage"
        case .tournoi: "Tournoi"
        case .competition: "Compétition"
        case .evenement: "Événement"
        case .adherents: "Adhérents"
        case .complet: "Complet"
        case .indisponible: "Indisponible"
        }
    }
}

/// Ligne de `slot_overrides` réduite à ce dont le planning a besoin.
nonisolated struct SlotOverrideRow: Decodable, Sendable {
    /// `court_id` : terrain bloqué.
    let courtId: UUID
    /// `heure_debut` (`time`), en texte.
    let heureDebut: String?
    /// `etat`, valeur brute (voir `SlotOverrideState`).
    let etat: String?
    /// `label` : texte libre saisi par l'admin (nom du cours pour un blocage
    /// posé par `creer_activite`).
    let label: String?

    /// Correspondance avec les colonnes SQL.
    enum CodingKeys: String, CodingKey {
        case etat, label
        case courtId = "court_id"
        case heureDebut = "heure_debut"
    }

    /// Colonnes demandées. `id`, `date` et `heure_fin` sont lues mais non
    /// décodées : seul le début du blocage compte pour la grille (voir la
    /// limite connue d'`AvailabilityEngine`).
    static let columns = "id, court_id, date, heure_debut, heure_fin, etat, label"

    /// Début du blocage, en minutes depuis minuit.
    var startMinutes: Int? {
        ClubSportSettingsRow.minutes(from: heureDebut)
    }

    /// Raison affichée : le libellé libre saisi par l'admin s'il existe, sinon
    /// l'état traduit, sinon un repli neutre.
    var reason: String {
        // Un libellé fait d'espaces seulement compte comme absent.
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        if let etat, let state = SlotOverrideState(rawValue: etat.lowercased()) {
            return state.label
        }
        return "Bloqué"
    }
}
