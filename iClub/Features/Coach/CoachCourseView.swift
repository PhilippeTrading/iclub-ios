//
//  CoachCourseView.swift
//  iClub
//
//  La fiche d'un cours, côté entraîneur : inscrits (contacts, règlement en
//  lecture seule), séances passées et à venir, écrire au groupe ou à un
//  inscrit, annuler une séance.
//

import SwiftUI

struct CoachCourseView: View {
    let activityId: UUID
    let store: CoachStore

    @Environment(ClubCatalog.self) private var catalog
    @Environment(MessagingCenter.self) private var messaging
    @Environment(\.openURL) private var openURL

    @Environment(AppRouter.self) private var router

    @State private var sessionToCancel: ActivitySession?
    /// Élève dont la petite fiche est ouverte.
    @State private var quickStudentId: UUID?
    @State private var isOpeningGroup = false

    private var activity: Activity? { store.activity(id: activityId) }

    var body: some View {
        ScrollView {
            if let activity {
                VStack(alignment: .leading, spacing: 18) {
                    header(activity)
                    rosterCard(activity)
                    sessionsCard(activity)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            } else {
                PhasePlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: "Cours introuvable",
                    message: "Il a peut-être été annulé ou terminé."
                )
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(activity?.nom ?? "Cours")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
        .sheet(isPresented: Binding(get: { quickStudentId != nil }, set: { if !$0 { quickStudentId = nil } })) {
            if let id = quickStudentId, let enrollment = store.roster(of: activityId).first(where: { $0.id == id }) {
                StudentQuickSheet(student: StudentInfo(enrollment: enrollment, store: store)) {
                    router.activitiesPath.append(StudentRoute(enrollmentId: enrollment.id, activityId: activityId))
                }
            }
        }
        .sheet(item: $sessionToCancel) { session in
            CancelSessionSheet(session: session) {
                await store.reload()
            }
        }
    }

    // MARK: - En-tête

    private func header(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                BrandChip(title: activity.type.singularLabel, tint: activity.sport.accent)
                BrandChip(title: activity.statut.label, tint: activity.statut == .proposee ? Brand.warning : Brand.success)
                BrandChip(title: store.placesLabel(for: activity), tint: Brand.navy700)
            }

            if let schedule = activity.usualSchedule {
                Text([schedule, courtName(activity.courtId)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }

            if activity.statut == .proposee {
                InlineMessage(kind: .info, message: "En attente de validation par le club : les membres ne peuvent pas encore s'inscrire.")
            }

            Button {
                isOpeningGroup = true
                Task {
                    await messaging.openGroup(activityId: activity.id)
                    isOpeningGroup = false
                }
            } label: {
                Label("Écrire au groupe", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .disabled(isOpeningGroup || store.enrolled(in: activity.id).isEmpty)
        }
    }

    // MARK: - Inscrits

    private func rosterCard(_ activity: Activity) -> some View {
        let roster = store.roster(of: activity.id)

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inscrits")
                    .metaLabelStyle()

                if roster.isEmpty {
                    Text("Personne n'est encore inscrit.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                ForEach(roster) { enrollment in
                    enrollmentRow(enrollment)
                        .contentShape(.rect)
                        .onTapGesture { quickStudentId = enrollment.id }
                    if enrollment.id != roster.last?.id { Divider().opacity(0.4) }
                }
            }
        }
    }

    private func enrollmentRow(_ enrollment: ActivityEnrollment) -> some View {
        let info = enrollment.profileId.flatMap { store.people[$0] }
        let name = store.displayName(of: enrollment)

        return HStack(alignment: .top, spacing: 12) {
            MemberAvatar(
                url: info?.avatarUrl.flatMap(URL.init(string:)),
                initials: info?.initials ?? String(name.prefix(1)),
                size: 38
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    if enrollment.statut == .listeAttente {
                        BrandChip(title: "Attente \(enrollment.rangListeAttente.map(String.init) ?? "")", tint: Brand.warning)
                            .fixedSize()
                    }
                }

                if let phone = PhoneNumber.formattedForDisplay(enrollment.telephone) {
                    Text(phone).font(.caption).foregroundStyle(Brand.textSecondary)
                }
                if let email = enrollment.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
                if let comment = enrollment.commentaire, !comment.isEmpty {
                    Text(comment).font(.caption).italic().foregroundStyle(Brand.textSecondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                // Lecture seule : c'est le club qui enregistre le règlement.
                BrandChip(title: enrollment.reglement.label, tint: paymentTint(enrollment.reglement))
                    .fixedSize()
                contactMenu(enrollment, name: name)
            }
        }
    }

    /// Un inscrit qui a un compte reçoit un message ; sans compte, on propose
    /// l'appel ou le SMS.
    private func contactMenu(_ enrollment: ActivityEnrollment, name: String) -> some View {
        let phoneDigits = enrollment.telephone.map(PhoneNumber.normalize)

        return Menu {
            if let profileId = enrollment.profileId {
                Button("Écrire dans l'app", systemImage: "bubble.left.fill") {
                    Task { await messaging.startConversation(with: profileId) }
                }
            }
            if let phoneDigits, !phoneDigits.isEmpty {
                Button("Appeler", systemImage: "phone.fill") {
                    if let url = URL(string: "tel:\(phoneDigits)") { openURL(url) }
                }
                Button("Envoyer un SMS", systemImage: "message.fill") {
                    if let url = URL(string: "sms:\(phoneDigits)") { openURL(url) }
                }
            }
            if let email = enrollment.email, !email.isEmpty,
               let url = URL(string: "mailto:\(email)") {
                Button("Envoyer un e-mail", systemImage: "envelope.fill") { openURL(url) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(Brand.navy700)
        }
        .accessibilityLabel("Contacter \(name)")
    }

    private func paymentTint(_ status: PaymentStatus) -> Color {
        switch status {
        case .du: Brand.warning
        case .encaisse: Brand.success
        case .offert: Brand.navy700
        }
    }

    // MARK: - Séances

    private func sessionsCard(_ activity: Activity) -> some View {
        let sessions = store.sessions[activity.id] ?? []
        let today = Calendar.current.startOfDay(for: .now)
        let upcoming = sessions.filter { $0.date >= today }
        let past = sessions.filter { $0.date < today }.reversed()

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Séances")
                    .metaLabelStyle()

                if sessions.isEmpty {
                    Text("Aucune séance.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                ForEach(upcoming) { session in sessionRow(session, activity: activity, isPast: false) }

                if !past.isEmpty {
                    Text("Passées")
                        .metaLabelStyle()
                        .padding(.top, 6)
                    ForEach(Array(past)) { session in sessionRow(session, activity: activity, isPast: true) }
                }
            }
        }
    }

    private func sessionRow(_ session: ActivitySession, activity: Activity, isPast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(session.statut == .annulee ? Brand.textSecondary : Brand.textPrimary)
                    .strikethrough(session.statut == .annulee)

                let details = [
                    courtName(session.courtId),
                    substitute(session, activity: activity).map { "Remplaçant : \($0)" },
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                if let note = session.noteSeance, !note.isEmpty {
                    Text("Note : \(note)").font(.caption).foregroundStyle(Brand.textSecondary)
                }
                if session.statut == .annulee, let motif = session.motifAnnulation {
                    Text("Annulée : \(motif)").font(.caption).foregroundStyle(Brand.error)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                BrandChip(title: session.statut.label, tint: statusTint(session.statut))
                    .fixedSize()

                if session.statut != .annulee && session.statut != .reportee && (isPast || session.isToday) {
                    NavigationLink(value: AttendanceRoute(sessionId: session.id)) {
                        Text(session.statut == .faite ? "Appel" : "Faire l'appel")
                            .font(.caption.weight(.semibold))
                    }
                }
                if session.statut == .prevue && !isPast {
                    Button("Annuler", role: .destructive) { sessionToCancel = session }
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func statusTint(_ status: SessionStatus) -> Color {
        switch status {
        case .prevue: Brand.navy700
        case .faite: Brand.success
        case .annulee: Brand.error
        case .reportee: Brand.warning
        }
    }

    private func substitute(_ session: ActivitySession, activity: Activity) -> String? {
        guard let id = session.entraineurProfileId, id != activity.entraineurProfileId else { return nil }
        return store.people[id]?.displayName
    }

    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }
}

// MARK: - Annuler une séance

/// Le motif est obligatoire : les inscrits le liront.
struct CancelSessionSheet: View {
    let session: ActivitySession
    let onCancelled: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var motif = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var trimmedMotif: String { motif.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                        .font(.subheadline.weight(.medium))
                } footer: {
                    Text("Le terrain est rendu à la réservation.")
                }

                Section("Motif") {
                    TextField("Pluie, entraîneur malade…", text: $motif, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let errorMessage {
                    Section { InlineMessage(kind: .error, message: errorMessage) }
                }
            }
            .navigationTitle("Annuler la séance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retour") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Annuler la séance", role: .destructive) { cancel() }
                        .disabled(trimmedMotif.isEmpty || isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cancel() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await CoachService.cancelSession(session.id, motif: trimmedMotif)
                Haptics.destructive()
                await onCancelled()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
            isWorking = false
        }
    }
}
