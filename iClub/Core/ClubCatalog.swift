//
//  ClubCatalog.swift
//  iClub
//
//  Catalogue du club partagé par l'accueil, le tunnel de réservation et les
//  parties ouvertes : terrains actifs et horaires par sport.
//
//  Il s'abonne aux changements de la table `courts` en temps réel : si l'admin
//  ajoute, désactive ou réordonne un terrain depuis le back-office web, l'app
//  se met à jour sans relancement ni nouvelle version.
//

import Foundation
import Observation
import Supabase

@Observable
final class ClubCatalog {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var courts: [Court] = []
    private(set) var settings: [Sport: ClubSportSettings] = [:]

    private var clubId: UUID?

    // MARK: - Lectures dérivées

    /// Sports proposés par le club, c'est-à-dire ceux qui ont au moins un
    /// terrain actif. Un sport sans terrain n'apparaît nulle part dans l'app.
    ///
    /// `courts.ordre` classe les terrains *à l'intérieur* d'un sport et repart
    /// de 1 pour chacun : il ne dit rien de l'ordre entre sports. On garde donc
    /// l'ordre canonique tennis → padel → pickleball, celui du web.
    var availableSports: [Sport] {
        let played = Set(courts.map(\.sport))
        return Sport.allCases.filter(played.contains)
    }

    /// Terrains d'un sport, dans l'ordre d'affichage voulu par l'admin
    /// (`ordre`, appliqué côté serveur puis re-garanti ici).
    func courts(for sport: Sport) -> [Court] {
        courts.filter { $0.sport == sport }.sorted { $0.ordre < $1.ordre }
    }

    /// Tout compteur de terrains se calcule ici, jamais en dur.
    func courtCount(for sport: Sport) -> Int {
        courts(for: sport).count
    }

    /// Surfaces distinctes d'un sport, triées par nombre de terrains
    /// décroissant puis par nom pour départager. Entièrement dérivé de
    /// `courts.surface` : si l'admin crée un terrain avec une surface inédite,
    /// la pastille correspondante apparaît sans nouvelle version de l'app.
    func surfaces(for sport: Sport) -> [String] {
        let counts = courts(for: sport)
            .compactMap(\.surface)
            .filter { !$0.isEmpty }
            .reduce(into: [String: Int]()) { counts, surface in
                counts[surface, default: 0] += 1
            }

        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    func settings(for sport: Sport) -> ClubSportSettings {
        settings[sport] ?? .fallback(for: sport)
    }

    /// Heure de fermeture du club : la plus tardive parmi tous les sports.
    ///
    /// `nil` tant que `club_sport_settings` n'a pas répondu — l'accueil
    /// n'affiche alors rien plutôt qu'une heure inventée.
    var latestClosingMinutes: Int? {
        settings.values.map(\.fermetureMinutes).max()
    }

    // MARK: - Cycle de vie

    /// Charge le catalogue puis reste à l'écoute jusqu'à annulation de la tâche
    /// appelante. À utiliser depuis un `.task(id:)`, qui gère le démontage.
    func activate(clubId: UUID) async {
        self.clubId = clubId
        await reload()
        await observeCourtChanges(clubId: clubId)
    }

    func reload() async {
        guard let clubId else { return }
        if courts.isEmpty { state = .loading }

        do {
            async let courtsTask = PlanningService.loadCourts(clubId: clubId)
            async let settingsTask = PlanningService.loadSportSettings(clubId: clubId)

            courts = try await courtsTask
            settings = await settingsTask
            state = .loaded
        } catch {
            // On garde les terrains déjà chargés : une coupure réseau ne doit
            // pas vider l'écran de l'utilisateur.
            state = courts.isEmpty
                ? .failed(error.localizedDescription)
                : .loaded
        }
    }

    // MARK: - Temps réel

    private func observeCourtChanges(clubId: UUID) async {
        let channel = Supa.client.channel("club-courts-\(clubId.uuidString)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "courts")

        await channel.subscribe()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Le filtre par club se fait côté client : le volume est négligeable et
        // cela évite de dépendre de la syntaxe de filtre du serveur Realtime.
        for await _ in changes {
            await reload()
        }
    }
}
