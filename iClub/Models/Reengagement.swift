//
//  Reengagement.swift
//  iClub
//
//  Règles de relance d'un membre qui ne joue plus, en fonction pure.
//
//  Une suggestion part si TOUT est vrai :
//    1. aucune partie jouée depuis le plus long de : 14 jours, ou deux fois
//       l'intervalle habituel du membre entre deux parties ;
//    2. aucune réservation à venir (sinon, il est actif) ;
//    3. on ne sait pas qu'il est hors de la zone du club — la position ne
//       sert qu'à BLOQUER une relance, jamais à la rendre possible ;
//    4. une partie ouverte lui correspond réellement ;
//    5. au plus deux relances par période d'inactivité, espacées de 14 jours,
//       puis plus rien jusqu'à sa prochaine partie.
//
//  Tout se calcule sur le téléphone. Rien n'est envoyé au serveur.
//

import Foundation

/// Ce que l'app sait de la présence du membre dans la zone du club.
nonisolated enum ZoneState: Sendable, Equatable {
    case inside
    case outside
    /// Position refusée, non activée, ou pas encore connue d'iOS. Dans le
    /// doute on envoie : on ne bloque que si l'on SAIT qu'il est loin.
    case unknown
}

/// Mémoire locale des relances, conservée sur l'appareil.
nonisolated struct ReengagementState: Codable, Sendable, Equatable {
    /// Date de référence de la période d'inactivité en cours : la dernière
    /// partie jouée au moment des relances. Si elle change, le membre a rejoué,
    /// et le compteur repart de zéro.
    var anchor: Date?
    var sentCount = 0
    var lastSentAt: Date?
}

nonisolated enum ReengagementPolicy {

    static let day: TimeInterval = 86_400
    static let minimumInactivity: TimeInterval = 14 * day
    static let retryDelay: TimeInterval = 14 * day
    static let maxReminders = 2
    /// Rayon de la zone autour du club, en mètres.
    static let zoneRadius: Double = 40_000
    /// Écart toléré avec l'heure habituelle de jeu.
    static let usualTimeTolerance = 120

    // MARK: - Historique

    nonisolated struct History: Sendable {
        /// Début des parties effectivement jouées (passées, non annulées).
        let playedStarts: [Date]
        let hasUpcoming: Bool
        /// Sports pratiqués, du plus joué au moins joué.
        let sportsByFrequency: [Sport]
        /// Heure de début habituelle, en minutes depuis minuit.
        let usualStartMinutes: Int?

        var lastPlayed: Date? { playedStarts.max() }
    }

    static func history(from reservations: [MyReservation], now: Date = .now) -> History {
        let played = reservations.filter { !$0.isCancelled && $0.startsAt < now }

        let counts = played.compactMap(\.sport).reduce(into: [Sport: Int]()) { $0[$1, default: 0] += 1 }
        let sports = counts.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map(\.key)

        return History(
            playedStarts: played.map(\.startsAt),
            hasUpcoming: reservations.contains { !$0.isCancelled && $0.startsAt >= now },
            sportsByFrequency: sports,
            usualStartMinutes: median(played.map(\.slot.startMinutes))
        )
    }

    // MARK: - Seuil d'inactivité

    /// Le plus long de 14 jours ou de deux fois l'intervalle habituel : un
    /// joueur hebdomadaire est relancé à 14 jours, un mensuel vers 60.
    static func inactivityThreshold(playedStarts: [Date]) -> TimeInterval {
        let calendar = Calendar.current
        let days = Set(playedStarts.map { calendar.startOfDay(for: $0) }).sorted()
        let gaps = zip(days, days.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .suffix(10)

        guard let usual = median(Array(gaps)) else { return minimumInactivity }
        return max(minimumInactivity, 2 * usual)
    }

    // MARK: - Décision

    nonisolated enum Decision: Equatable, Sendable {
        case remind
        case wait(String)
    }

    /// - Parameter firstSeen: première évaluation sur cet appareil, qui sert de
    ///   départ pour un membre qui n'a encore jamais joué.
    static func decide(
        history: History,
        state: ReengagementState,
        zone: ZoneState,
        firstSeen: Date,
        now: Date = .now
    ) -> Decision {
        if history.hasUpcoming { return .wait("réservation à venir") }

        let anchor = history.lastPlayed ?? firstSeen
        let inactivity = now.timeIntervalSince(anchor)
        let threshold = inactivityThreshold(playedStarts: history.playedStarts)
        if inactivity < threshold { return .wait("pas encore inactif") }

        // Le membre a rejoué depuis les dernières relances : nouvelle période.
        let current = state.anchor == anchor ? state : ReengagementState(anchor: anchor)
        if current.sentCount >= maxReminders { return .wait("deux relances déjà envoyées") }
        if let last = current.lastSentAt, now.timeIntervalSince(last) < retryDelay {
            return .wait("relance trop récente")
        }

        if zone == .outside { return .wait("hors de la zone du club") }
        return .remind
    }

    /// État après l'envoi d'une relance.
    static func recordingReminder(_ state: ReengagementState, history: History, firstSeen: Date, now: Date = .now) -> ReengagementState {
        let anchor = history.lastPlayed ?? firstSeen
        var next = state.anchor == anchor ? state : ReengagementState(anchor: anchor)
        next.sentCount += 1
        next.lastSentAt = now
        return next
    }

    // MARK: - Choix de la partie

    /// Une partie qu'il peut réellement rejoindre, dans un sport qu'il
    /// pratique, au plus près de son heure habituelle, la plus proche dans le
    /// temps. `nil` s'il n'y en a aucune : on ne relance jamais pour rien.
    static func bestGame(
        among games: [OpenGame],
        profile: SessionProfile,
        history: History
    ) -> OpenGame? {
        let calendar = Calendar.current

        let candidates = games.filter { game in
            guard game.isOpenForJoining, !game.contains(profile.id) else { return false }
            if !history.sportsByFrequency.isEmpty, !history.sportsByFrequency.contains(game.sport) {
                return false
            }
            let engagedSameDay = games.contains {
                $0.id != game.id && !$0.isCancelled
                    && calendar.isDate($0.date, inSameDayAs: game.date)
                    && $0.contains(profile.id)
            }
            return OpenGameEligibility.refusal(
                joining: game, profile: profile, engagedSameDay: engagedSameDay
            ) == nil
        }

        func score(_ game: OpenGame) -> (Int, Int, Date) {
            let sportRank = history.sportsByFrequency.firstIndex(of: game.sport) ?? 0
            let timeRank: Int
            if let usual = history.usualStartMinutes {
                timeRank = abs(game.slot.startMinutes - usual) <= usualTimeTolerance ? 0 : 1
            } else {
                timeRank = 0
            }
            return (timeRank, sportRank, game.startsAt)
        }

        return candidates.min { score($0) < score($1) }
    }

    // MARK: - Texte

    /// Le message parle de la partie, jamais de la position du membre.
    @MainActor static func notificationContent(for game: OpenGame) -> (title: String, body: String) {
        let format = game.format == .double ? "en double" : "en simple"
        let title = "Partie de \(game.sport.displayName.lowercased()) \(format)"
        let places = game.freeSlots > 1 ? "\(game.freeSlots) places libres" : "1 place libre"
        let body = "\(game.date.longFrenchDate) à \(game.slot.startLabel) · \(game.courtName) · \(places). Rejoignez-la avant qu'elle soit complète."
        return (title, body)
    }

    // MARK: - Outils

    private static func median<T: BinaryInteger>(_ values: [T]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Int(sorted[sorted.count / 2])
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
