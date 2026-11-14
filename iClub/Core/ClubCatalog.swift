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
//  Place dans l'application
//    Créé par `iClubApp`, injecté en environnement, activé par `MainTabView`
//    (`.task(id:)` sur le club du membre). Lit, via `PlanningService`, les tables
//    `courts` et `club_sport_settings` et la fonction SQL `terrains_interdits`.
//    La table `courts` fait partie de la publication temps réel
//    `supabase_realtime` (migration `20260923110000_realtime_all_tables.sql`).
//
//  Droits et sécurité
//    `courts` et `club_sport_settings` sont lisibles par tous (catalogue public
//    du club, RLS `courts_select_public`). Les terrains fermés à un groupe sont
//    cachés ici pour le confort, mais c'est la base qui interdit réellement la
//    réservation (déclencheurs `acces_terrain` et `acces_terrain_partie`).
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage par défaut du
//    projet). Les deux lectures du catalogue partent en parallèle (`async let`).
//

import Foundation
import Observation
import Supabase

/// Terrains et horaires du club, tenus à jour en temps réel.
@Observable
final class ClubCatalog {

    /// État du chargement, pour l'affichage d'un indicateur ou d'une erreur.
    enum State: Equatable {
        /// Pas encore activé.
        case idle
        /// Premier chargement en cours (aucun terrain en mémoire).
        case loading
        /// Catalogue disponible (éventuellement celui d'avant une erreur réseau).
        case loaded
        /// Premier chargement impossible ; message de l'erreur.
        case failed(String)
    }

    /// État courant du catalogue.
    private(set) var state: State = .idle
    /// Tous les terrains actifs du club. Pour retrouver le nom d'un terrain ;
    /// pour réserver, passer par `courts(for:)`, qui écarte les terrains fermés.
    private(set) var courts: [Court] = []
    /// Horaires et horizon de réservation par sport (`club_sport_settings`).
    /// Un sport absent prend les valeurs de repli (`settings(for:)`).
    private(set) var settings: [Sport: ClubSportSettings] = [:]

    /// Terrains que la personne au nom de qui l'on réserve ne peut pas
    /// réserver (`terrains_interdits`). Vide par défaut, et en cas d'échec :
    /// la base refuse de toute façon une réservation interdite.
    ///
    /// On n'annonce jamais un terrain caché : il n'apparaît simplement pas.
    private(set) var forbiddenCourtIds: Set<UUID> = []

    /// Club activé, retenu pour `reload()` et `refreshAccess(childId:)`.
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

    /// Terrains **réservables** d'un sport, dans l'ordre voulu par l'admin
    /// (`ordre`, appliqué côté serveur puis re-garanti ici). Planning, création
    /// de partie et compteurs passent tous par là.
    ///
    /// - Parameter sport: sport demandé.
    /// - Returns: terrains actifs du sport, moins ceux de `forbiddenCourtIds`.
    func courts(for sport: Sport) -> [Court] {
        allCourts(for: sport).filter { !forbiddenCourtIds.contains($0.id) }
    }

    /// Tous les terrains actifs d'un sport, fermés compris : pour ce qui ne
    /// relève pas d'une réservation (un entraîneur qui crée son cours).
    ///
    /// - Parameter sport: sport demandé.
    /// - Returns: terrains triés par `ordre` croissant.
    func allCourts(for sport: Sport) -> [Court] {
        courts.filter { $0.sport == sport }.sorted { $0.ordre < $1.ordre }
    }

    /// - Parameter courtId: terrain (`courts.id`).
    /// - Returns: `true` si ce terrain est fermé à la personne au nom de qui
    ///   l'on réserve.
    func isForbidden(_ courtId: UUID) -> Bool {
        forbiddenCourtIds.contains(courtId)
    }

    /// Tout compteur de terrains se calcule ici, jamais en dur.
    ///
    /// - Parameter sport: sport demandé.
    /// - Returns: nombre de terrains réservables du sport.
    func courtCount(for sport: Sport) -> Int {
        courts(for: sport).count
    }

    /// Surfaces distinctes d'un sport, triées par nombre de terrains
    /// décroissant puis par nom pour départager. Entièrement dérivé de
    /// `courts.surface` : si l'admin crée un terrain avec une surface inédite,
    /// la pastille correspondante apparaît sans nouvelle version de l'app.
    ///
    /// - Parameter sport: sport demandé.
    /// - Returns: libellés de surface tels que saisis par l'admin ; une surface
    ///   vide ou absente n'en produit pas.
    func surfaces(for sport: Sport) -> [String] {
        // Décompte par surface, sur les seuls terrains réservables.
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

    /// Horaires d'un sport.
    ///
    /// - Parameter sport: sport demandé.
    /// - Returns: la ligne `club_sport_settings` du sport, ou le repli
    ///   (9 h à 21 h, 7 jours) si le club n'en a pas.
    func settings(for sport: Sport) -> ClubSportSettings {
        settings[sport] ?? .fallback(for: sport)
    }

    /// Heure de fermeture du club : la plus tardive parmi tous les sports.
    ///
    /// `nil` tant que `club_sport_settings` n'a pas répondu : l'accueil
    /// n'affiche alors rien plutôt qu'une heure inventée.
    var latestClosingMinutes: Int? {
        settings.values.map(\.fermetureMinutes).max()
    }

    // MARK: - Terrains fermés

    /// Relit les terrains fermés pour la personne au nom de qui l'on réserve :
    /// soi (`childId == nil`) ou un enfant. Pas de temps réel sur ce réglage :
    /// à rappeler à chaque affichage du planning et des parties, au « tirer
    /// pour actualiser », et au retour de l'app au premier plan.
    ///
    /// - Parameter childId: profil de l'enfant au nom de qui l'on réserve, ou
    ///   `nil` pour le compte connecté.
    func refreshAccess(childId: UUID? = nil) async {
        guard let clubId else { return }
        forbiddenCourtIds = await PlanningService.forbiddenCourts(clubId: clubId, for: childId)
    }

    // MARK: - Cycle de vie

    /// Charge le catalogue puis reste à l'écoute jusqu'à annulation de la tâche
    /// appelante. À utiliser depuis un `.task(id:)`, qui gère le démontage.
    ///
    /// - Parameter clubId: club du membre connecté.
    func activate(clubId: UUID) async {
        self.clubId = clubId
        await reload()
        // Ne rend la main qu'à l'annulation de la tâche (déconnexion,
        // changement de club).
        await observeCourtChanges(clubId: clubId)
    }

    /// Relit terrains et horaires du club activé.
    ///
    /// Une erreur sur les terrains ne vide pas un catalogue déjà chargé ; une
    /// erreur sur les horaires n'en est pas une (lecture tolérante, repli par
    /// sport).
    func reload() async {
        guard let clubId else { return }
        // Indicateur de chargement seulement au premier passage : un
        // rafraîchissement ne doit pas faire clignoter l'écran.
        if courts.isEmpty { state = .loading }

        do {
            // Les deux lectures partent en parallèle.
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

    /// S'abonne aux changements de `courts` (insertion, modification,
    /// suppression) et relit le catalogue à chaque événement. Le canal est
    /// retiré du client à l'annulation de la tâche.
    ///
    /// - Parameter clubId: club activé, qui donne son nom au canal.
    private func observeCourtChanges(clubId: UUID) async {
        let channel = Supa.client.channel("club-courts-\(clubId.uuidString)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "courts")

        await channel.subscribe()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        // Aucun filtre par club sur l'abonnement : un changement de terrain dans
        // n'importe quel club déclenche un rechargement, qui ne relit que les
        // terrains du club courant. Le volume est négligeable et cela évite de
        // dépendre de la syntaxe de filtre du serveur Realtime.
        for await _ in changes {
            await reload()
        }
    }
}
