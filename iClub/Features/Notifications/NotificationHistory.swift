//
//  NotificationHistory.swift
//  iClub
//
//  L'historique des notifications, ouvert par la cloche en haut à droite.
//
//  Trois sources :
//    • les annonces du club (`annonces`), pour tous les membres, adhérents ou
//      non : elles n'envoient pas de notification push, elles vivent ici ;
//    • les parties proposées (`notifications_envoyees`), conservées en base ;
//    • les messages, que la base ne journalise pas : on reprend ceux encore
//      présents dans le centre de notifications de l'iPhone.
//
//  Place dans l'application
//    `NotificationHistoryView` est présenté en feuille par la cloche de la
//    barre du haut (`AppTopBar`), qui se sert aussi de
//    `NotificationHistoryService` pour compter les nouveautés de sa pastille.
//
//  Données et droits
//    - Annonces : `ClubContentService.announcements` (table `annonces`, les 30
//      dernières encore actives du club).
//    - Parties proposées : table `notifications_envoyees`, lue sans filtre
//      explicite ; sa politique RLS (« mes notifications ») ne rend que les
//      lignes du compte connecté. La réservation et le terrain sont joints
//      pour composer le titre.
//    - Messages : notifications de type « message » encore affichées dans le
//      centre de notifications de l'appareil.
//    Chaque source est tolérante à l'échec : elle rend alors une liste vide.
//
//  Nouveautés
//    La date de dernière consultation est gardée sur l'appareil
//    (`UserDefaults`) ; tout élément plus récent compte dans la pastille de la
//    cloche et apparaît en gras.
//
//  Points d'attention
//    - Cette date est propre à l'appareil, pas au compte : deux comptes
//      utilisés tour à tour sur le même iPhone la partagent.
//    - Quand on agit pour un enfant, les parties proposées restent celles du
//      compte connecté (la RLS se fonde sur l'utilisateur authentifié).
//

import Foundation
import Supabase
import SwiftUI
import UserNotifications

// MARK: - Modèle

/// Un élément de l'historique, quelle que soit sa source.
struct NotificationHistoryItem: Identifiable, Hashable {
    /// Nature de l'élément, et ce qu'il faut pour l'ouvrir.
    enum Kind: Hashable {
        /// Partie proposée : réservation de la partie, et vrai si le membre l'a
        /// rejointe ensuite (`rejointe_le` renseigné).
        case openGame(reservationId: UUID, joined: Bool)
        /// Message reçu : conversation à ouvrir.
        case message(conversationId: UUID)
        /// Annonce du club, lue sur place.
        case announcement(Announcement)
    }

    /// Identifiant stable et unique entre sources : « annonce-… », « game-… »
    /// ou « message-… ».
    let id: String
    /// Nature de l'élément.
    let kind: Kind
    /// Titre affiché en gras.
    let title: String
    /// Texte sous le titre (deux lignes au plus à l'écran).
    let body: String
    /// Date de l'élément : publication, envoi ou réception ; sert au tri et
    /// au calcul des nouveautés.
    let date: Date
}

/// Ligne lue dans `notifications_envoyees`, avec la réservation de la partie
/// et son terrain (jointures `reservations` puis `courts`).
private nonisolated struct SentNotificationRow: Decodable, Sendable {
    /// Identifiant de l'envoi.
    let id: UUID
    /// Réservation de la partie proposée ; `nil` si elle a disparu.
    let reservationId: UUID?
    /// Raison de l'envoi : « partenaire » ou « habitude ».
    let motif: String?
    /// Date d'envoi (`timestamptz`, texte ISO 8601).
    let envoyeeLe: String?
    /// Date à laquelle le membre a rejoint la partie, `nil` sinon.
    let rejointeLe: String?
    /// Réservation jointe (colonne `reservations` de la réponse).
    let reservation: ReservationPart?

    /// Partie utile de la réservation : jour, heure de début, terrain.
    struct ReservationPart: Decodable, Sendable {
        /// Jour (`date` Postgres, « 2026-09-23 »).
        let date: String?
        /// Heure de début (`time` Postgres, « 18:30:00 »).
        let heureDebut: String?
        /// Terrain joint (colonne `courts`).
        let courts: CourtPart?

        /// Colonnes lues : `date`, `heure_debut` et la jointure `courts`.
        enum CodingKeys: String, CodingKey {
            case date, courts
            case heureDebut = "heure_debut"
        }
    }

    /// Partie utile du terrain : nom et sport.
    struct CourtPart: Decodable, Sendable {
        /// Nom du terrain.
        let nom: String?
        /// Sport (`courts.sport`).
        let sport: String?
    }

    /// Colonnes de `notifications_envoyees` (`id`, `motif`, `reservation_id`,
    /// `envoyee_le`, `rejointe_le`) et jointure `reservations`.
    enum CodingKeys: String, CodingKey {
        case id, motif
        case reservationId = "reservation_id"
        case envoyeeLe = "envoyee_le"
        case rejointeLe = "rejointe_le"
        case reservation = "reservations"
    }
}

// MARK: - Service

/// Lecture de l'historique et suivi des nouveautés.
enum NotificationHistoryService {

    /// Clé `UserDefaults` de la date de dernière consultation.
    private static let lastSeenKey = "notifications.lastSeen"

    /// Rassemble les trois sources, du plus récent au plus ancien.
    ///
    /// - Parameter clubId: club du compte connecté ; `nil` (session pas encore
    ///   connue) prive seulement des annonces.
    /// - Returns: les éléments triés par date décroissante ; jamais d'erreur.
    static func load(clubId: UUID?) async -> [NotificationHistoryItem] {
        // Les trois lectures partent en parallèle.
        async let games = openGameItems()
        async let messages = messageItems()
        async let announcements = announcementItems(clubId: clubId)
        return (await games + messages + announcements).sorted { $0.date > $1.date }
    }

    /// Annonces actives du club, publiées par l'administration.
    /// Une annonce sans date de création est écartée (elle ne saurait être
    /// classée).
    private static func announcementItems(clubId: UUID?) async -> [NotificationHistoryItem] {
        guard let clubId else { return [] }
        return await ClubContentService.announcements(clubId: clubId, limit: 30).compactMap { announcement in
            guard let date = announcement.createdAt else { return nil }
            return NotificationHistoryItem(
                id: "annonce-\(announcement.id)",
                kind: .announcement(announcement),
                title: announcement.title,
                body: announcement.body,
                date: date
            )
        }
    }

    /// Les parties proposées au membre, du plus récent au plus ancien.
    ///
    /// Les 50 derniers envois, filtrés par la RLS sur le compte connecté. Le
    /// titre se compose du sport et du moment (« Padel aujourd'hui à 18 h 30 »),
    /// le texte du terrain et de la raison de l'envoi.
    private static func openGameItems() async -> [NotificationHistoryItem] {
        let rows: [Lenient<SentNotificationRow>] = (try? await Supa.client
            .from("notifications_envoyees")
            .select("id, reservation_id, motif, envoyee_le, rejointe_le, reservations(date, heure_debut, courts(nom, sport))")
            .order("envoyee_le", ascending: false)
            .limit(50)
            .execute()
            .value) ?? []

        return rows.compactValues().compactMap { row in
            // Sans réservation ni date d'envoi lisible, l'élément est écarté.
            guard let reservationId = row.reservationId,
                  let date = SupabaseDate.parse(row.envoyeeLe) else { return nil }

            // Sport (« Partie » s'il est inconnu), jour relatif sans majuscule
            // et heure : « Padel demain à 18 h 30 ».
            let sport = row.reservation?.courts?.sport.flatMap(Sport.init(rawValue:))?.displayName ?? "Partie"
            let day = SupabaseDate.parse(row.reservation?.date)?.relativeFrenchDayTitle.lowercasedFirst
            let time = PostgresTime.minutes(from: row.reservation?.heureDebut).map(TimeSlot.clock)
            let when = [day, time.map { "à \($0)" }].compactMap { $0 }.joined(separator: " ")
            let court = row.reservation?.courts?.nom

            return NotificationHistoryItem(
                id: "game-\(row.id)",
                kind: .openGame(reservationId: reservationId, joined: row.rejointeLe != nil),
                title: "\(sport) \(when)".trimmingCharacters(in: .whitespaces),
                // Terrain, puis la raison de l'envoi, séparés par « · ».
                body: [court, row.motif == "partenaire" ? "Un partenaire habituel y joue." : "C'est l'un de vos créneaux habituels."]
                    .compactMap { $0 }.joined(separator: " · "),
                date: date
            )
        }
    }

    /// Messages encore affichés dans le centre de notifications.
    /// Seules les notifications de type « message » portant un identifiant de
    /// conversation valide sont reprises ; celles que le membre a effacées de
    /// l'iPhone n'apparaissent plus.
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

    /// Émise quand l'historique vient d'être consulté : toutes les cloches
    /// (une par onglet) effacent leur pastille.
    static let seenNotification = Notification.Name("iclub.notificationsSeen")

    /// Date de la dernière consultation de l'historique ; le passé lointain si
    /// l'historique n'a jamais été ouvert sur cet appareil. L'écrire prévient
    /// toutes les cloches.
    static var lastSeen: Date {
        get { UserDefaults.standard.object(forKey: lastSeenKey) as? Date ?? .distantPast }
        set {
            UserDefaults.standard.set(newValue, forKey: lastSeenKey)
            NotificationCenter.default.post(name: seenNotification, object: nil)
        }
    }

    /// Nombre d'éléments postérieurs à la dernière consultation.
    ///
    /// - Parameter items: historique chargé.
    /// - Returns: le nombre de nouveautés, pour la pastille de la cloche.
    static func unseenCount(_ items: [NotificationHistoryItem]) -> Int {
        let since = lastSeen
        return items.filter { $0.date > since }.count
    }
}

// MARK: - Écran

/// Feuille « Notifications » : la liste mêlée des annonces, parties proposées
/// et messages, du plus récent au plus ancien.
struct NotificationHistoryView: View {
    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Navigation : ouverture d'une partie dans l'onglet « Parties ».
    @Environment(AppRouter.self) private var router
    /// Messagerie : ouverture d'une conversation.
    @Environment(MessagingCenter.self) private var messaging
    /// Session : club du compte connecté.
    @Environment(AuthController.self) private var auth
    /// Annonce ouverte en feuille par-dessus l'historique.
    @State private var openedAnnouncement: Announcement?

    /// Éléments affichés.
    @State private var items: [NotificationHistoryItem] = []
    /// Vrai après le premier chargement.
    @State private var isLoaded = false
    /// Repère figé à l'ouverture : ce qui est nouveau reste marqué tant que
    /// l'écran est affiché.
    @State private var seenBefore = NotificationHistoryService.lastSeen

    /// Feuille avec sa barre de titre : chargement, écran vide ou liste.
    var body: some View {
        NavigationStack {
            Group {
                // Chargement, liste vide, ou liste.
                if !isLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    PhasePlaceholder(
                        systemImage: "bell",
                        title: "Aucune notification",
                        message: "Les annonces du club, les parties proposées sur vos créneaux et les messages reçus apparaîtront ici."
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
            // « Tirer pour actualiser » : relit les trois sources, sans
            // toucher à la date de consultation.
            .refreshable { items = await NotificationHistoryService.load(clubId: auth.sessionProfile?.clubId) }
            // Annonce lue sur place.
            .sheet(item: $openedAnnouncement) { announcement in
                AnnouncementSheet(announcement: announcement)
            }
            // Premier chargement, puis l'historique est noté comme consulté :
            // toutes les pastilles des cloches s'effacent.
            .task {
                items = await NotificationHistoryService.load(clubId: auth.sessionProfile?.clubId)
                isLoaded = true
                NotificationHistoryService.lastSeen = .now
            }
        }
    }

    /// Ligne d'un élément : pictogramme de la source, titre (en gras s'il est
    /// nouveau) et date, texte, puis le niveau d'une annonce importante ou la
    /// mention d'une partie rejointe.
    ///
    /// - Parameter item: élément affiché.
    /// - Returns: la ligne.
    private func row(_ item: NotificationHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(item))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.navy700)
                .frame(width: 34, height: 34)
                .background(Brand.navy700.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    // Gras pour ce qui est arrivé depuis la consultation
                    // précédente.
                    Text(item.title)
                        .font(.system(.subheadline, design: .rounded, weight: item.date > seenBefore ? .bold : .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // « 14 h 05 », « hier », « lun. » ou « 12 oct. ».
                    Text(item.date.conversationTimestamp)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                Text(item.body)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(2)
                // Niveau d'une annonce, sauf « Information » (le cas courant).
                if case .announcement(let announcement) = item.kind, announcement.level != .information {
                    BrandChip(title: announcement.level.displayName, tint: announcement.level.tint)
                }
                // Partie proposée que le membre a rejointe.
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

    /// Pictogramme de la source de l'élément.
    ///
    /// - Parameter item: élément concerné.
    /// - Returns: le nom du symbole SF (joueur, bulle ou mégaphone).
    private func symbol(_ item: NotificationHistoryItem) -> String {
        switch item.kind {
        case .openGame: "figure.tennis"
        case .message: "bubble.left.fill"
        case .announcement: "megaphone.fill"
        }
    }

    /// Même destination qu'un tap sur la notification elle-même.
    ///
    /// Une partie s'ouvre dans l'onglet « Parties », à la place de ce qui y
    /// était empilé ; un message ouvre sa conversation. Contrairement au tap
    /// sur la notification push, ce chemin ne signale pas l'ouverture à la
    /// base (`notification_vue`).
    ///
    /// - Parameter item: élément touché.
    private func open(_ item: NotificationHistoryItem) {
        // Une annonce se lit sur place, sans quitter l'historique.
        if case .announcement(let announcement) = item.kind {
            openedAnnouncement = announcement
            return
        }
        dismiss()
        switch item.kind {
        case .announcement:
            break
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

// MARK: - Annonce

/// Feuille de lecture d'une annonce du club : niveau, titre, date de
/// publication et texte complet.
private struct AnnouncementSheet: View {
    /// Annonce affichée.
    let announcement: Announcement
    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Texte de l'annonce, défilant, avec un bouton de fermeture.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Niveau, sauf « Information ».
                    if announcement.level != .information {
                        BrandChip(title: announcement.level.displayName, tint: announcement.level.tint)
                    }
                    Text(announcement.title)
                        .font(.editorial(.title3))
                        .foregroundStyle(Brand.navy800)
                    // « Publiée le 1er septembre 2026 », si la date est connue.
                    if let date = announcement.createdAt {
                        Text("Publiée le \(date.frenchDayMonthYear)")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Text(announcement.body)
                        .font(.body)
                        .foregroundStyle(Brand.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Annonce du club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
            }
        }
        // Demi-hauteur, extensible à toute la hauteur pour une annonce longue.
        .presentationDetents([.medium, .large])
    }
}
