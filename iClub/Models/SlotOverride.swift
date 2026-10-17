//
//  SlotOverride.swift
//  iClub
//
//  Blocages posés par l'admin depuis le back-office web. Un override rend un
//  créneau indisponible au même titre qu'une réservation, et c'est lui qui
//  fournit la raison affichée en gris sur l'écran de choix du terrain.
//

import Foundation

/// Valeurs de la colonne `slot_overrides.etat`. Un état inconnu de l'app ne doit
/// pas produire une case vide : le repli est géré par `SlotOverrideRow.reason`.
nonisolated enum SlotOverrideState: String, Sendable {
    case maintenance
    case ferme
    case cours
    case stage
    case tournoi
    case competition
    case evenement
    case adherents
    case complet
    case indisponible

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

nonisolated struct SlotOverrideRow: Decodable, Sendable {
    let courtId: UUID
    let heureDebut: String?
    let etat: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case etat, label
        case courtId = "court_id"
        case heureDebut = "heure_debut"
    }

    static let columns = "id, court_id, date, heure_debut, heure_fin, etat, label"

    /// Début du blocage, en minutes depuis minuit.
    var startMinutes: Int? {
        ClubSportSettingsRow.minutes(from: heureDebut)
    }

    /// Raison affichée : le libellé libre saisi par l'admin s'il existe, sinon
    /// l'état traduit, sinon un repli neutre.
    var reason: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        if let etat, let state = SlotOverrideState(rawValue: etat.lowercased()) {
            return state.label
        }
        return "Bloqué"
    }
}
