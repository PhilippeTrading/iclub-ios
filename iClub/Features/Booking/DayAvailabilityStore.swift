//
//  DayAvailabilityStore.swift
//  iClub
//
//  Réservations et blocages du club pour *un* jour. Le magasin ne garde que les
//  données brutes : la grille est recalculée par `AvailabilityEngine` à partir
//  des terrains du `ClubCatalog`. Un terrain ajouté ou désactivé par l'admin est
//  donc pris en compte sans invalidation manuelle ici.
//
//  Le périmètre est (club, jour), pas (club, jour, sport) : une seule requête
//  couvre les trois sports, et changer de sport n'entraîne aucun aller-retour.
//

import Foundation
import Observation
import Supabase

@Observable
final class DayAvailabilityStore {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var reservations: [ReservationRow] = []
    private(set) var overrides: [SlotOverrideRow] = []

    private var clubId: UUID?
    private var date: Date?
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    // MARK: - Cycle de vie

    /// Charge le jour demandé puis reste à l'écoute jusqu'à annulation de la
    /// tâche appelante. À utiliser depuis un `.task(id:)`, qui gère le démontage.
    func activate(clubId: UUID, date: Date) async {
        if self.clubId != clubId || self.date.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) ?? true {
            // Changement de jour : les données précédentes ne veulent plus rien
            // dire, on repart d'un écran de chargement propre.
            reservations = []
            overrides = []
            phase = .idle
        }

        self.clubId = clubId
        self.date = date

        await reload()
        await observeChanges(clubId: clubId)
    }

    func reload() async {
        guard let clubId, let date else { return }
        if phase != .ready { phase = .loading }

        do {
            async let reservationsTask = PlanningService.loadReservations(clubId: clubId, date: date)
            async let overridesTask = PlanningService.loadSlotOverrides(clubId: clubId, date: date)

            reservations = try await reservationsTask
            overrides = try await overridesTask
            phase = .ready
        } catch {
            // Afficher des créneaux libres alors qu'on n'a pas pu lire les
            // réservations serait pire que de ne rien afficher : on échoue franchement.
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Grille

    /// Grille du sport pour le jour courant, recalculée à la demande. Le coût
    /// est négligeable (quelques centaines d'itérations) et cela garantit que
    /// l'affichage suit à la fois le magasin et le catalogue de terrains.
    func slots(for sport: Sport, catalog: ClubCatalog) -> [SlotAvailability] {
        guard let date else { return [] }

        return AvailabilityEngine.slots(
            courts: catalog.courts(for: sport),
            settings: catalog.settings(for: sport),
            reservations: reservations,
            overrides: overrides,
            date: date
        )
    }

    // MARK: - Temps réel

    /// `reservations` et `slot_overrides` sont suivies pour que la liste reste
    /// juste pendant que l'écran est ouvert : quelqu'un peut confirmer le même
    /// créneau à la même seconde. Les terrains sont suivis par `ClubCatalog`.
    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("booking-availability-\(clubId.uuidString)")
        let reservationChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "reservations")
        let overrideChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "slot_overrides")

        // Un abonnement qui échoue ne doit pas casser l'écran : la liste reste
        // exacte au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Le filtre par club se fait côté client, comme dans `ClubCatalog` : le
        // volume est négligeable et cela évite de dépendre de la syntaxe de
        // filtre du serveur Realtime.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await _ in reservationChanges { await self?.scheduleReload() }
            }
            group.addTask { [weak self] in
                for await _ in overrideChanges { await self?.scheduleReload() }
            }
        }
    }

    /// Une confirmation côté web émet souvent plusieurs événements d'affilée.
    /// On les regroupe derrière un court délai plutôt que de relire la base à
    /// chacun.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
