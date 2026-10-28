//
//  ActivityDetailView.swift
//  iClub
//
//  Détail d'une activité, côté membre : description, séances à venir, règles,
//  tarif, entraîneur, et inscription.
//
//  L'inscription passe par `inscrire_activite`, qui tranche tout : inscrit ou
//  liste d'attente, refus d'âge ou de niveau, fenêtre fermée. L'app ne fait
//  qu'afficher la réponse.
//

import SwiftUI

struct ActivityDetailView: View {
    let activityId: UUID
    let store: ActivitiesStore

    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(MessagingCenter.self) private var messaging

    @State private var managedProfiles: [ManagedProfile] = []
    @State private var isChoosingPerson = false
    @State private var isWorking = false
    @State private var confirmUnenroll = false
    @State private var resultMessage: (title: String, message: String)?
    @State private var errorMessage: String?

    private var activity: Activity? { store.activity(id: activityId) }

    var body: some View {
        Group {
            if let activity {
                content(activity)
            } else {
                PhasePlaceholder(
                    systemImage: "calendar.badge.exclamationmark",
                    title: "Activité indisponible",
                    message: "Elle n'est plus proposée par le club."
                )
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(activity?.type.singularLabel ?? "Activité")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            managedProfiles = await ActivityService.managedProfiles(clubId: clubId)
        }
        .confirmationDialog("Inscrire qui ?", isPresented: $isChoosingPerson, titleVisibility: .visible) {
            ForEach(eligiblePeople) { person in
                Button(person.estMoi ? "Moi-même" : person.displayName) {
                    enroll(person)
                }
            }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog(
            "Se désinscrire ?",
            isPresented: $confirmUnenroll,
            titleVisibility: .visible
        ) {
            Button("Se désinscrire", role: .destructive) { unenroll() }
            Button("Rester inscrit", role: .cancel) {}
        } message: {
            Text("Votre place sera proposée à la première personne en liste d'attente.")
        }
        .alert(resultMessage?.title ?? "", isPresented: resultBinding) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage?.message ?? "")
        }
        .alert("Inscription impossible", isPresented: errorBinding) {
            Button("J'ai compris") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Contenu

    private func content(_ activity: Activity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(activity)

                if let description = activity.description, !description.isEmpty {
                    SurfaceCard {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                sessionsCard(activity)
                rulesCard(activity)
                coachCard(activity)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) { actionBar(activity) }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
    }

    private func header(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activity.nom)
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)

            HStack(spacing: 6) {
                BrandChip(title: activity.sport.displayName, systemImage: activity.sport.symbolName, tint: activity.sport.accent)
                BrandChip(title: store.placesLabel(for: activity), tint: activity.isFull ? Brand.textSecondary : activity.sport.accent)
                if store.isEnrolled(activity.id) {
                    BrandChip(title: "Inscrit", systemImage: "checkmark", tint: Brand.success)
                }
            }

            if let schedule = activity.usualSchedule {
                Text([schedule, courtName(activity.courtId) ?? activity.lieu].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    // MARK: - Séances

    private func sessionsCard(_ activity: Activity) -> some View {
        let sessions = store.upcoming[activity.id] ?? []

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Séances à venir")
                    .metaLabelStyle()

                if sessions.isEmpty {
                    Text("Aucune séance programmée pour l'instant.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                } else {
                    ForEach(sessions) { session in
                        sessionRow(session, activity: activity)
                        if session.id != sessions.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: ActivitySession, activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.textPrimary)

            let place = courtName(session.courtId)
            let substitute = substituteName(session, activity: activity)
            if place != nil || substitute != nil {
                Text([place, substitute.map { "Remplacé par \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    /// Un remplaçant n'est signalé que s'il diffère de l'entraîneur habituel.
    private func substituteName(_ session: ActivitySession, activity: Activity) -> String? {
        guard let id = session.entraineurProfileId, id != activity.entraineurProfileId else { return nil }
        return store.name(of: id)
    }

    // MARK: - Règles et tarif

    private func rulesCard(_ activity: Activity) -> some View {
        let rows: [(String, String)] = [
            activity.ageLabel.map { ("Âge", $0) },
            activity.levelLabel.map { ("Niveau", $0.replacingOccurrences(of: "Niveau ", with: "")) },
            ("Places", "\(activity.placesMax)" + (activity.listeAttenteMax > 0 ? ", puis liste d'attente de \(activity.listeAttenteMax)" : "")),
            period(activity).map { ("Période", $0) },
            enrollmentWindow(activity).map { ("Inscriptions", $0) },
            activity.priceLabel.map { ("Tarif", $0) },
        ].compactMap { $0 }

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Conditions")
                    .metaLabelStyle()

                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                        Spacer(minLength: 12)
                        Text(row.1)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Brand.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if activity.priceLabel != nil {
                    Text("Tarif indicatif, réglé au club.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    private func period(_ activity: Activity) -> String? {
        switch (activity.dateDebut, activity.dateFin) {
        case let (start?, end?): "Du \(start.shortFrenchDate) au \(end.shortFrenchDate)"
        case let (start?, nil): "À partir du \(start.shortFrenchDate)"
        default: nil
        }
    }

    private func enrollmentWindow(_ activity: Activity) -> String? {
        switch (activity.inscriptionsOuvertesDu, activity.inscriptionsOuvertesAu) {
        case let (start?, end?): "Du \(start.shortFrenchDate) au \(end.shortFrenchDate)"
        case let (start?, nil): "À partir du \(start.shortFrenchDate)"
        case let (nil, end?): "Jusqu'au \(end.shortFrenchDate)"
        default: nil
        }
    }

    // MARK: - Entraîneur

    @ViewBuilder
    private func coachCard(_ activity: Activity) -> some View {
        if let name = store.coachName(for: activity) {
            SurfaceCard {
                HStack(spacing: 12) {
                    let info = activity.entraineurProfileId.flatMap { store.people[$0] }
                    MemberAvatar(
                        url: info?.avatarUrl.flatMap(URL.init(string:)),
                        initials: info?.initials ?? String(name.prefix(1)),
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encadré par")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                        Text(name)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                    }
                    Spacer(minLength: 8)

                    // Seul un entraîneur qui a un compte peut recevoir un message,
                    // et on ne s'écrit pas à soi-même.
                    if let coachId = activity.entraineurProfileId, coachId != auth.sessionProfile?.id {
                        Button {
                            Task { await messaging.startConversation(with: coachId) }
                        } label: {
                            Label("Écrire", systemImage: "bubble.left.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Inscription

    @ViewBuilder
    private func actionBar(_ activity: Activity) -> some View {
        VStack(spacing: 6) {
            if let mine = store.myEnrollment(in: activity.id) {
                Text(mine.statut == .listeAttente
                     ? "Vous êtes en liste d'attente\(mine.rangListeAttente.map { ", rang \($0)" } ?? "")."
                     : "Vous êtes inscrit à cette activité.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                Button(role: .destructive) {
                    confirmUnenroll = true
                } label: {
                    Text(mine.statut == .listeAttente ? "Quitter la liste d'attente" : "Se désinscrire")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .tint(Brand.error)
                .foregroundStyle(Brand.error)
                .disabled(isWorking)
            } else {
                PrimaryActionButton(
                    title: activity.isFull ? "Rejoindre la liste d'attente" : "S'inscrire",
                    systemImage: "plus",
                    isLoading: isWorking,
                    tint: activity.sport.accent
                ) {
                    startEnrollment()
                }
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Ceux au nom de qui le membre peut inscrire : lui-même, et les enfants
    /// dont il a la charge pour les activités.
    private var eligiblePeople: [ManagedProfile] {
        managedProfiles.filter { $0.estMoi || $0.peutInscrireActivites }
    }

    private func startEnrollment() {
        // Compte d'un enfant sélectionné en haut : c'est lui qu'on inscrit.
        if auth.isActingForChild, let child = eligiblePeople.first(where: { $0.profileId == auth.activeProfile?.id }) {
            enroll(child)
            return
        }
        // « Pour qui ? » seulement quand il y a vraiment un choix.
        if eligiblePeople.count > 1 {
            isChoosingPerson = true
        } else {
            enroll(nil)
        }
    }

    private func enroll(_ person: ManagedProfile?) {
        isWorking = true
        let forId = (person?.estMoi ?? true) ? nil : person?.profileId
        let who = forId == nil ? nil : person?.prenom ?? person?.displayName

        Task {
            do {
                let result = try await ActivityService.enroll(activityId: activityId, forProfileId: forId)
                Haptics.success()
                resultMessage = Self.resultText(result, who: who)
                await store.reload()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private static func resultText(_ result: EnrollmentResult, who: String?) -> (title: String, message: String) {
        let subject = who ?? "Vous"
        switch result.statut {
        case .listeAttente:
            let rank = result.rang.map { ", au rang \($0)" } ?? ""
            return ("Liste d'attente", "\(subject == "Vous" ? "Vous êtes" : "\(subject) est") en liste d'attente\(rank). Une place libérée vous sera attribuée automatiquement.")
        default:
            return ("Inscription confirmée", "\(subject == "Vous" ? "Vous êtes inscrit" : "\(subject) est inscrit") à cette activité.")
        }
    }

    private func unenroll() {
        guard let mine = store.myEnrollment(in: activityId) else { return }
        isWorking = true
        Task {
            do {
                try await ActivityService.unenroll(inscriptionId: mine.id)
                Haptics.destructive()
                await store.reload()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // MARK: - Outils

    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
