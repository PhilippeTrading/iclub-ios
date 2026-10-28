//
//  NotificationHistory.swift
//  iClub
//
//  L'historique des notifications, ouvert par la cloche en haut à droite.
//
//  Deux sources, parce que la base n'en garde qu'une :
//    • les parties proposées (`notifications_envoyees`), conservées en base ;
//    • les messages, que la base ne journalise pas : on reprend ceux encore
//      présents dans le centre de notifications de l'iPhone.
//

import Foundation
import Supabase
import SwiftUI
import UserNotifications

// MARK: - Modèle

struct NotificationHistoryItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case openGame(reservationId: UUID, joined: Bool)
        case message(conversationId: UUID)
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let date: Date
}

private nonisolated struct SentNotificationRow: Decodable, Sendable {
    let id: UUID
    let reservationId: UUID?
    let motif: String?
    let envoyeeLe: String?
    let rejointeLe: String?
    let reservation: ReservationPart?

    struct ReservationPart: Decodable, Sendable {
        let date: String?
        let heureDebut: String?
        let courts: CourtPart?

        enum CodingKeys: String, CodingKey {
            case date, courts
            case heureDebut = "heure_debut"
        }
    }

    struct CourtPart: Decodable, Sendable {
        let nom: String?
        let sport: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, motif
        case reservationId = "reservation_id"
        case envoyeeLe = "envoyee_le"
        case rejointeLe = "rejointe_le"
        case reservation = "reservations"
    }
}

// MARK: - Service

enum NotificationHistoryService {

    private static let lastSeenKey = "notifications.lastSeen"

    static func load() async -> [NotificationHistoryItem] {
        async let games = openGameItems()
        async let messages = messageItems()
        return (await games + messages).sorted { $0.date > $1.date }
    }

    /// Les parties proposées au membre, du plus récent au plus ancien.
    private static func openGameItems() async -> [NotificationHistoryItem] {
        let rows: [Lenient<SentNotificationRow>] = (try? await Supa.client
            .from("notifications_envoyees")
            .select("id, reservation_id, motif, envoyee_le, rejointe_le, reservations(date, heure_debut, courts(nom, sport))")
            .order("envoyee_le", ascending: false)
            .limit(50)
            .execute()
            .value) ?? []

        return rows.compactValues().compactMap { row in
            guard let reservationId = row.reservationId,
                  let date = SupabaseDate.parse(row.envoyeeLe) else { return nil }

            let sport = row.reservation?.courts?.sport.flatMap(Sport.init(rawValue:))?.displayName ?? "Partie"
            let day = SupabaseDate.parse(row.reservation?.date)?.relativeFrenchDayTitle.lowercasedFirst
            let time = PostgresTime.minutes(from: row.reservation?.heureDebut).map(TimeSlot.clock)
            let when = [day, time.map { "à \($0)" }].compactMap { $0 }.joined(separator: " ")
            let court = row.reservation?.courts?.nom

            return NotificationHistoryItem(
                id: "game-\(row.id)",
                kind: .openGame(reservationId: reservationId, joined: row.rejointeLe != nil),
                title: "\(sport) \(when)".trimmingCharacters(in: .whitespaces),
                body: [court, row.motif == "partenaire" ? "Un partenaire habituel y joue." : "C'est l'un de vos créneaux habituels."]
                    .compactMap { $0 }.joined(separator: " · "),
                date: date
            )
        }
    }

    /// Messages encore affichés dans le centre de notifications.
    private static func messageItems() async -> [NotificationHistoryItem] {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.compactMap { notification in
            let content = notification.request.content
            guard (content.userInfo["type"] as? String) == "message",
                  let raw = content.userInfo["conversation_id"] as? String,
                  let conversationId = UUID(uuidString: raw) else { return nil }
            return NotificationHistoryItem(
                id: "message-\(notification.request.identifier)",
                kind: .message(conversationId: conversationId),
                title: content.title,
                body: content.body,
                date: notification.date
            )
        }
    }

    // MARK: - Nouveautés

    static var lastSeen: Date {
        get { UserDefaults.standard.object(forKey: lastSeenKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    static func hasUnseen(_ items: [NotificationHistoryItem]) -> Bool {
        items.contains { $0.date > lastSeen }
    }
}

// MARK: - Écran

struct NotificationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(MessagingCenter.self) private var messaging

    @State private var items: [NotificationHistoryItem] = []
    @State private var isLoaded = false
    /// Repère figé à l'ouverture : ce qui est nouveau reste marqué tant que
    /// l'écran est affiché.
    @State private var seenBefore = NotificationHistoryService.lastSeen

    var body: some View {
        NavigationStack {
            Group {
                if !isLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    PhasePlaceholder(
                        systemImage: "bell",
                        title: "Aucune notification",
                        message: "Les parties proposées sur vos créneaux et les messages reçus apparaîtront ici."
                    )
                } else {
                    List(items) { item in
                        Button { open(item) } label: { row(item) }
                            .buttonStyle(.plain)
                            .listRowBackground(Brand.surface)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .refreshable { items = await NotificationHistoryService.load() }
            .task {
                items = await NotificationHistoryService.load()
                isLoaded = true
                NotificationHistoryService.lastSeen = .now
            }
        }
    }

    private func row(_ item: NotificationHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(item))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.navy700)
                .frame(width: 34, height: 34)
                .background(Brand.navy700.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.system(.subheadline, design: .rounded, weight: item.date > seenBefore ? .bold : .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.date.conversationTimestamp)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                Text(item.body)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(2)
                if case .openGame(_, true) = item.kind {
                    Text("Vous l'avez rejointe")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.success)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func symbol(_ item: NotificationHistoryItem) -> String {
        switch item.kind {
        case .openGame: "figure.tennis"
        case .message: "bubble.left.fill"
        }
    }

    /// Même destination qu'un tap sur la notification elle-même.
    private func open(_ item: NotificationHistoryItem) {
        dismiss()
        switch item.kind {
        case .openGame(let reservationId, _):
            var path = NavigationPath()
            path.append(OpenGameDetailRoute(gameId: reservationId))
            router.openGamesPath = path
            router.selectedTab = .openGames
        case .message(let conversationId):
            messaging.open(conversationId: conversationId)
        }
    }
}
