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
//  Place dans l'application
//    Appelé par `DayAvailabilityStore.slots(for:catalog:)` (écran de choix du
//    créneau et du terrain), avec les terrains réservables du sport
//    (`ClubCatalog.courts(for:)`), les réservations et les blocages du jour
//    (`PlanningService`).
//
//  Points d'attention
//    - Limite connue : une réservation ou un blocage n'occupe que la case de
//      son heure de début. Une réservation de deux créneaux, ou un blocage dont
//      `heure_fin` couvre plusieurs créneaux, laisse les cases suivantes
//      affichées libres ; la contrainte d'unicité de la base ne porte, elle
//      aussi, que sur l'heure de début (`court_id, date, heure_debut`).
//    - Les heures et la date du jour sont celles de l'appareil (`Calendar`
//      courant), pas celles du fuseau du club (`clubs.timezone`).
//

import Foundation

/// Moteur de disponibilité du planning : construit la grille des créneaux d'un
/// jour et l'état de chaque terrain dans chacun.
enum AvailabilityEngine {

    /// Clé d'index (terrain, minute de début) : évite de rebalayer les
    /// réservations et les blocages pour chaque case de la grille.
    private struct CourtMinute: Hashable {
        /// Terrain (`courts.id`).
        let courtId: UUID
        /// Début du créneau, en minutes depuis minuit.
        let minutes: Int
    }

    /// Grille complète du sport pour un jour donné.
    ///
    /// - Parameters:
    ///   - courts: terrains **actifs** du sport, dans l'ordre `ordre`.
    ///   - settings: horaires du sport (ouverture et fermeture en minutes
    ///     depuis minuit), qui bornent la grille.
    ///   - reservations: lignes `confirmee` du club pour ce jour, tous sports
    ///     confondus ; l'index par `court_id` écarte naturellement les autres.
    ///   - overrides: blocages du club pour ce jour (`slot_overrides`).
    ///   - date: jour affiché, utilisé pour masquer les créneaux déjà passés.
    ///   - now: instant de référence, injectable pour les essais.
    ///   - calendar: calendrier de calcul, celui de l'appareil par défaut.
    /// - Returns: un `SlotAvailability` par créneau (couple début et durée),
    ///   trié par heure de début puis par durée. Les créneaux déjà commencés
    ///   le jour même sont écartés.
    static func slots(
        courts: [Court],
        settings: ClubSportSettings,
        reservations: [ReservationRow],
        overrides: [SlotOverrideRow],
        date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SlotAvailability] {

        // Index des cases réservées. Une ligne dont l'heure est illisible est
        // ignorée (elle ne bloque rien).
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

        // Regroupement par créneau : chaque case réunit l'état de tous les
        // terrains qui proposent ce créneau.
        var grid: [TimeSlot: [CourtSlotState]] = [:]

        for court in courts {
            // La durée vient du terrain, jamais d'une constante.
            let step = court.dureeCreneauMinutes
            // Une durée nulle ou négative bouclerait sans fin : terrain ignoré.
            guard step > 0 else { continue }

            var start = settings.ouvertureMinutes
            // Aucun créneau ne doit déborder après la fermeture.
            while start + step <= settings.fermetureMinutes {
                let key = CourtMinute(courtId: court.id, minutes: start)

                // Ordre de priorité de la règle : blocage, puis réservation.
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
            // Aujourd'hui, un créneau dont l'heure de début est passée n'est
            // plus proposé ; un créneau qui commence à la minute même l'est
            // encore. Les autres jours, rien n'est masqué.
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
    ///
    /// - Parameters:
    ///   - date: jour affiché.
    ///   - now: instant présent.
    ///   - calendar: calendrier (et donc fuseau) de comparaison.
    /// - Returns: heure et minute actuelles en minutes depuis minuit, ou `nil`.
    private static func pastCutoffMinutes(for date: Date, now: Date, calendar: Calendar) -> Int? {
        guard calendar.isDate(date, inSameDayAs: now) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return hour * 60 + minute
    }
}
