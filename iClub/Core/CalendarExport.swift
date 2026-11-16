//
//  CalendarExport.swift
//  iClub
//
//  Ajout d'une réservation au calendrier de l'appareil.
//
//  On demande l'accès *en écriture seule* (`requestWriteOnlyAccessToEvents`) :
//  l'app n'a besoin que de créer un événement, jamais de lire l'agenda. C'est
//  le niveau d'autorisation le plus faible qui permette d'écrire, et il est
//  couvert par `NSCalendarsWriteOnlyAccessUsageDescription` (texte de la
//  demande déclaré dans les réglages du projet Xcode).
//
//  Place dans l'application
//    Bouton « Ajouter à mon calendrier » de l'écran de confirmation d'une
//    réservation (`BookingConfirmedView`).
//
//  Effets de bord
//    Crée un événement dans le calendrier par défaut de l'appareil. Rien n'est
//    écrit en base ; l'événement n'est ni mis à jour ni supprimé si la
//    réservation est annulée ensuite.
//

import EventKit
import Foundation

/// Erreurs de l'export vers le calendrier, avec leur message affichable.
enum CalendarExportError: LocalizedError {
    /// Le membre a refusé l'accès, maintenant ou auparavant (réglage iOS).
    case accessDenied

    /// Message montré sous le bouton d'export.
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "L'accès au calendrier a été refusé. Tu peux l'autoriser dans Réglages."
        }
    }
}

/// Export d'une réservation vers EventKit.
enum CalendarExport {

    /// Crée l'événement dans le calendrier choisi par l'utilisateur.
    ///
    /// - Parameters:
    ///   - title: titre de l'événement : nom du terrain et nom du club, séparés
    ///     par un tiret (titre composé par `BookingConfirmation.eventTitle`).
    ///   - start: début du créneau (heure locale de l'appareil).
    ///   - end: fin du créneau.
    ///   - notes: texte libre de l'événement (la liste des joueurs), ou `nil`.
    /// - Throws: `CalendarExportError.accessDenied` si l'accès est refusé ;
    ///   l'erreur d'EventKit si l'enregistrement échoue.
    static func addEvent(
        title: String,
        start: Date,
        end: Date,
        notes: String?
    ) async throws {
        let store = EKEventStore()

        // `.writeOnly` et `.fullAccess` conviennent tous deux pour écrire.
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            // Première fois : iOS présente sa fenêtre d'autorisation.
            guard try await store.requestWriteOnlyAccessToEvents() else {
                throw CalendarExportError.accessDenied
            }
        } else if status != .writeOnly && status != .fullAccess {
            // Refusé ou restreint : iOS ne reposera pas la question, seul le
            // réglage de l'app peut rétablir l'accès.
            throw CalendarExportError.accessDenied
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        // Calendrier par défaut choisi par l'utilisateur dans les réglages d'iOS.
        event.calendar = store.defaultCalendarForNewEvents

        try store.save(event, span: .thisEvent)
    }
}
