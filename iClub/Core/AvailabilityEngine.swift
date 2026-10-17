//
//  AvailabilityEngine.swift
//  iClub
//
//  Calcul des disponibilités, reproduit à l'identique de l'app web : toute
//  divergence produirait deux plannings qui ne racontent pas la même chose.
//
//  Fonction pure, sans accès réseau ni état : elle se teste telle quelle et se
//  relance à chaque événement temps réel sans effet de bord.
//
//  La règle, dans cet ordre de priorité, pour chaque couple (terrain, créneau) :
//
//    1. un `slot_overrides` sur ce terrain à cette heure → indisponible,
//       raison = `etat` (ou le `label` libre saisi par l'admin) ;
//    2. sinon une `reservations` confirmée → indisponible, raison « Réservé » ;
//    3. sinon → disponible.
//
//  Les comparaisons d'heure passent par les minutes depuis minuit, jamais par la
//  chaîne brute : « 14:00:00 » et « 14:00 » désignent le même créneau.
//

import Foundation

enum AvailabilityEngine {

    /// Clé d'index (terrain, minute de début) : évite de rebalayer les
    /// réservations et les blocages pour chaque case de la grille.
    private struct CourtMinute: Hashable {
        let courtId: UUID
        let minutes: Int
    }

    /// Grille complète du sport pour un jour donné.
    ///
    /// - Parameters:
    ///   - courts: terrains **actifs** du sport, dans l'ordre `ordre`.
    ///   - reservations: lignes `confirmee` du club pour ce jour, tous sports
    ///     confondus — l'index par `court_id` écarte naturellement les autres.
    ///   - date: jour affiché, utilisé pour masquer les créneaux déjà passés.
    static func slots(
        courts: [Court],
        settings: ClubSportSettings,
        reservations: [ReservationRow],
        overrides: [SlotOverrideRow],
        date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SlotAvailability] {

        let reserved: Set<CourtMinute> = Set(
            reservations.compactMap { row in
                row.startMinutes.map { CourtMinute(courtId: row.courtId, minutes: $0) }
            }
        )

        // Un même créneau peut porter plusieurs blocages : le premier rencontré
        // fournit la raison, comme côté web.
        var blocked: [CourtMinute: String] = [:]
        for row in overrides {
            guard let minutes = row.startMinutes else { continue }
            let key = CourtMinute(courtId: row.courtId, minutes: minutes)
            if blocked[key] == nil { blocked[key] = row.reason }
        }

        var grid: [TimeSlot: [CourtSlotState]] = [:]

        for court in courts {
            // La durée vient du terrain, jamais d'une constante.
            let step = court.dureeCreneauMinutes
            guard step > 0 else { continue }

            var start = settings.ouvertureMinutes
            // Aucun créneau ne doit déborder après la fermeture.
            while start + step <= settings.fermetureMinutes {
                let key = CourtMinute(courtId: court.id, minutes: start)

                let availability: CourtAvailability
                if let reason = blocked[key] {
                    availability = .unavailable(reason: reason)
                } else if reserved.contains(key) {
                    availability = .unavailable(reason: "Réservé")
                } else {
                    availability = .available
                }

                let slot = TimeSlot(startMinutes: start, durationMinutes: step)
                grid[slot, default: []].append(CourtSlotState(court: court, availability: availability))

                start += step
            }
        }

        let cutoff = pastCutoffMinutes(for: date, now: now, calendar: calendar)

        return grid
            .filter { slot, _ in
                guard let cutoff else { return true }
                return slot.startMinutes >= cutoff
            }
            .map { SlotAvailability(slot: $0.key, courts: $0.value) }
            .sorted { $0.slot < $1.slot }
    }

    /// Minute avant laquelle un créneau est considéré comme passé, ou `nil` si
    /// le jour affiché n'est pas aujourd'hui (une journée future n'a pas de
    /// créneau passé, une journée antérieure n'est pas atteignable par la bande
    /// de dates).
    private static func pastCutoffMinutes(for date: Date, now: Date, calendar: Calendar) -> Int? {
        guard calendar.isDate(date, inSameDayAs: now) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return hour * 60 + minute
    }
}
