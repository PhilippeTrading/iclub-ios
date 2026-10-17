//
//  HomeStore.swift
//  iClub
//
//  Données de l'accueil : prochaine réservation, cours, annonces, crédits.
//
//  Un seul magasin pour tout l'écran, et un seul abonnement temps réel : un
//  autre membre qui rejoint la réservation, un admin qui publie une annonce ou
//  ajuste une adhésion doivent se voir sans délai perceptible.
//

import Foundation
import Observation
import Supabase

@Observable
final class HomeStore {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
    }

    private(set) var phase: Phase = .idle

    /// Réservation confirmée la plus proche où je figure — créée par moi ou
    /// non, exactement comme dans « Mes réservations ».
    private(set) var nextReservation: MyReservation?
    /// Photos des participants de cette réservation.
    private(set) var roster: [UUID: RosterInfoRow] = [:]
    private(set) var activities: [ClubActivity] = []
    private(set) var announcements: [Announcement] = []
    private(set) var credits: GuestCreditBalance = .none

    private var profile: SessionProfile?
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel() }

    static let activityLimit = 3
    static let announcementLimit = 2

    // MARK: - Cycle de vie

    /// Charge puis reste à l'écoute jusqu'à annulation de la tâche appelante.
    func activate(profile: SessionProfile) async {
        self.profile = profile
        await reload()
        await observeChanges(clubId: profile.clubId)
    }

    func reload() async {
        guard let profile else { return }
        if phase == .idle { phase = .loading }

        // Les quatre sections sont indépendantes : elles se chargent en
        // parallèle, et l'échec de l'une ne prive pas des autres.
        async let reservationsTask = loadNextReservation(profile: profile)
        async let activitiesTask = ClubContentService.activities(
            clubId: profile.clubId, limit: Self.activityLimit
        )
        async let announcementsTask = ClubContentService.announcements(
            clubId: profile.clubId, limit: Self.announcementLimit
        )
        async let creditsTask = GuestCreditService.balance(
            clubId: profile.clubId,
            clubMemberId: profile.clubMemberId,
            profileId: profile.id,
            period: profile.activeMembershipPeriod
        )

        let next = await reservationsTask
        nextReservation = next.reservation
        roster = next.roster
        activities = await activitiesTask
        announcements = await announcementsTask
        credits = await creditsTask

        phase = .ready
    }

    private func loadNextReservation(
        profile: SessionProfile
    ) async -> (reservation: MyReservation?, roster: [UUID: RosterInfoRow]) {
        do {
            let all = try await ReservationService.loadMine(
                clubId: profile.clubId,
                profileId: profile.id
            )
            let next = all
                .filter { !$0.isCancelled && $0.isUpcoming }
                .min { $0.startsAt < $1.startsAt }

            guard let next else { return (nil, [:]) }

            let ids = next.participants.compactMap(\.profileId)
            let info = ids.isEmpty ? [:] : await ClubDirectoryService.rosterInfo(profileIds: ids)
            return (next, info)
        } catch {
            // On garde ce qui est déjà affiché plutôt que de vider la carte.
            return (nextReservation, roster)
        }
    }

    // MARK: - Temps réel

    private func observeChanges(clubId: UUID) async {
        let channel = Supa.client.channel("home-\(clubId.uuidString)")

        // Cinq tables, un seul canal : les rafales sont regroupées en aval.
        let streams = [
            channel.postgresChange(AnyAction.self, schema: "public", table: "reservations"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "reservation_participants"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "annonces"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "memberships"),
            channel.postgresChange(AnyAction.self, schema: "public", table: "guest_credit_allowances"),
        ]

        // Un abonnement qui échoue ne doit pas casser l'écran : le contenu
        // reste exact au chargement et se rafraîchit au pull-to-refresh.
        try? await channel.subscribeWithError()
        defer {
            Task { await Supa.client.removeChannel(channel) }
        }

        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask { [weak self] in
                    for await _ in stream { await self?.scheduleReload() }
                }
            }
        }
    }

    /// Une seule action côté base émet souvent plusieurs événements. On les
    /// regroupe derrière un court délai plutôt que de tout relire à chacun.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
