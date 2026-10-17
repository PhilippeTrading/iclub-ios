//
//  CalendarExport.swift
//  iClub
//
//  Ajout d'une réservation au calendrier de l'appareil.
//
//  On demande l'accès *en écriture seule* (`requestWriteOnlyAccessToEvents`) :
//  l'app n'a besoin que de créer un événement, jamais de lire l'agenda. C'est
//  le niveau d'autorisation le plus faible qui permette d'écrire, et il est
//  couvert par `NSCalendarsWriteOnlyAccessUsageDescription`.
//

import EventKit
import Foundation

enum CalendarExportError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "L'accès au calendrier a été refusé. Tu peux l'autoriser dans Réglages."
        }
    }
}

enum CalendarExport {

    /// Crée l'événement dans le calendrier choisi par l'utilisateur.
    ///
    /// - Parameters:
    ///   - title: « {Nom du terrain} — {Nom du club} ».
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
            guard try await store.requestWriteOnlyAccessToEvents() else {
                throw CalendarExportError.accessDenied
            }
        } else if status != .writeOnly && status != .fullAccess {
            throw CalendarExportError.accessDenied
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        try store.save(event, span: .thisEvent)
    }
}
