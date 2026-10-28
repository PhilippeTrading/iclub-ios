//
//  StudentViews.swift
//  iClub
//
//  Un élève, vu par son entraîneur : la petite fiche qui s'ouvre par-dessus
//  l'appel, et la fiche complète.
//
//  Le téléphone est celui donné à l'inscription — souvent celui d'un parent
//  pour un enfant.
//

import SwiftUI

/// Fiche complète d'un élève, poussée dans la pile de l'onglet.
struct StudentRoute: Hashable {
    let enrollmentId: UUID
    let activityId: UUID
}

// MARK: - Informations communes

/// Ce qu'on sait d'un élève : son inscription, et son profil s'il a un compte.
struct StudentInfo {
    let enrollment: ActivityEnrollment
    let name: String
    let profile: RosterInfoRow?

    init(enrollment: ActivityEnrollment, store: CoachStore) {
        self.enrollment = enrollment
        self.name = store.displayName(of: enrollment)
        self.profile = enrollment.profileId.flatMap { store.people[$0] }
    }

    var avatarURL: URL? { profile?.avatarUrl.flatMap(URL.init(string:)) }

    var initials: String {
        if let profile { return profile.initials }
        let value = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    var birthDate: Date? { SupabaseDate.parse(profile?.dateNaissance) }

    var age: Int? {
        if let age = profile?.ageFromServer { return age }
        return birthDate.flatMap { Calendar.current.dateComponents([.year], from: $0, to: .now).year }
    }

    /// Chiffres seuls, pour `tel:` et `sms:`.
    var phoneDigits: String? {
        guard let phone = enrollment.telephone else { return nil }
        let digits = PhoneNumber.normalize(phone)
        return digits.isEmpty ? nil : digits
    }
}

/// Relevé de présence : « présent » compte les retards, « absent » compte les
/// absences excusées.
struct AttendanceSummary {
    let present: Int
    let late: Int
    let absent: Int

    init(_ rows: [AttendanceRow]) {
        present = rows.filter { $0.etat == .present || $0.etat == .retard }.count
        late = rows.filter { $0.etat == .retard }.count
        absent = rows.filter { $0.etat == .absent || $0.etat == .excuse }.count
    }
}

// MARK: - Boutons de contact

private struct ContactButtons: View {
    let student: StudentInfo
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let digits = student.phoneDigits {
            HStack(spacing: 10) {
                contactButton("Appeler", systemImage: "phone.fill", url: "tel:\(digits)")
                contactButton("SMS", systemImage: "message.fill", url: "sms:\(digits)")
            }
        } else {
            Text("Aucun téléphone renseigné à l'inscription.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
        }
    }

    private func contactButton(_ title: String, systemImage: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
    }
}

private struct AttendanceCounters: View {
    let summary: AttendanceSummary?

    var body: some View {
        HStack(spacing: 10) {
            counter("Présences", value: summary?.present, tint: Brand.success,
                    detail: summary.map { $0.late > 0 ? "dont \($0.late) retard\($0.late > 1 ? "s" : "")" : nil } ?? nil)
            counter("Absences", value: summary?.absent, tint: Brand.error, detail: nil)
        }
    }

    private func counter(_ title: String, value: Int?, tint: Color, detail: String?) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "–")
                .font(.numeral(.title2))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(Brand.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }
}

// MARK: - Petite fiche (fenêtre)

/// S'ouvre par-dessus l'appel, sans le quitter.
struct StudentQuickSheet: View {
    let student: StudentInfo
    let onOpenFullSheet: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var summary: AttendanceSummary?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        AvatarView(url: student.avatarURL, initials: student.initials, size: 110)
                        Text(student.name)
                            .font(.editorial(.title2))
                            .foregroundStyle(Brand.navy800)
                            .multilineTextAlignment(.center)
                        Text(identityLine)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    ContactButtons(student: student)
                    AttendanceCounters(summary: summary)

                    Button {
                        dismiss()
                        onOpenFullSheet()
                    } label: {
                        Text("Voir la fiche complète")
                            .font(.system(.headline, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.navy700)
                }
                .padding(20)
            }
            .background(Brand.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if let rows = try? await CoachService.attendanceHistory(inscriptionId: student.enrollment.id) {
                summary = AttendanceSummary(rows)
            }
        }
    }

    /// « 11 ans · né le 3 mars 2015 ».
    private var identityLine: String {
        var parts: [String] = []
        if let age = student.age { parts.append("\(age) ans") }
        if let birth = student.birthDate { parts.append("né le \(birth.frenchDayMonthYear)") }
        return parts.isEmpty ? "Âge non renseigné" : parts.joined(separator: " · ")
    }
}

// MARK: - Fiche complète

struct StudentDetailView: View {
    let route: StudentRoute
    let store: CoachStore

    @Environment(MessagingCenter.self) private var messaging
    @Environment(\.openURL) private var openURL
    @State private var history: [AttendanceRow] = []
    @State private var isLoaded = false

    private var enrollment: ActivityEnrollment? {
        store.enrollments[route.activityId]?.first { $0.id == route.enrollmentId }
    }

    var body: some View {
        ScrollView {
            if let enrollment {
                let student = StudentInfo(enrollment: enrollment, store: store)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        AvatarView(url: student.avatarURL, initials: student.initials, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(student.name)
                                .font(.editorial(.title3))
                                .foregroundStyle(Brand.navy800)
                            if let activity = store.activity(id: route.activityId) {
                                Text(activity.nom).font(.footnote).foregroundStyle(Brand.textSecondary)
                            }
                        }
                    }

                    infoCard(student)
                    ContactButtons(student: student)
                    if enrollment.profileId != nil || enrollment.email != nil {
                        moreContacts(student)
                    }
                    AttendanceCounters(summary: isLoaded ? AttendanceSummary(history) : nil)
                    historyCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            } else {
                PhasePlaceholder(systemImage: "person.crop.circle.badge.questionmark", title: "Élève introuvable", message: "Il n'est peut-être plus inscrit à ce cours.")
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Fiche de l'élève")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            history = (try? await CoachService.attendanceHistory(inscriptionId: route.enrollmentId)) ?? []
            isLoaded = true
        }
    }

    private func infoCard(_ student: StudentInfo) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                ProfileCardHeader(title: "Informations")
                LabeledContent("Âge", value: student.age.map { "\($0) ans" } ?? "Non renseigné")
                LabeledContent("Date de naissance", value: student.birthDate?.frenchDayMonthYear ?? "Non renseignée")
                LabeledContent("Téléphone", value: PhoneNumber.formattedForDisplay(student.enrollment.telephone) ?? "Non renseigné")
                if let email = student.enrollment.email, !email.isEmpty {
                    LabeledContent("E-mail") {
                        Text(email).lineLimit(1).truncationMode(.middle)
                    }
                }
                LabeledContent("Inscription", value: student.enrollment.statut == .listeAttente ? "Liste d'attente" : "Inscrit")
                LabeledContent("Règlement", value: student.enrollment.reglement.label)
                if let comment = student.enrollment.commentaire, !comment.isEmpty {
                    Text(comment).font(.footnote).italic().foregroundStyle(Brand.textSecondary)
                }
            }
            .font(.subheadline)
        }
    }

    private func moreContacts(_ student: StudentInfo) -> some View {
        HStack(spacing: 10) {
            if let profileId = student.enrollment.profileId {
                Button {
                    Task { await messaging.startConversation(with: profileId) }
                } label: {
                    Label("Écrire", systemImage: "bubble.left.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }
            if let email = student.enrollment.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                Button {
                    openURL(url)
                } label: {
                    Label("E-mail", systemImage: "envelope.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }
        }
    }

    /// Une ligne par séance passée ou pointée, la plus récente en premier.
    private var historyCard: some View {
        let byId = Dictionary(history.map { ($0.seanceId, $0.etat) }, uniquingKeysWith: { _, last in last })
        let today = Calendar.current.startOfDay(for: .now)
        let sessions = (store.sessions[route.activityId] ?? [])
            .filter { $0.date <= today || byId[$0.id] != nil }
            .filter { $0.statut != .annulee }
            .sorted { $0.date > $1.date }

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                ProfileCardHeader(title: "Relevé de présence")
                if sessions.isEmpty {
                    Text("Aucune séance passée pour l'instant.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                ForEach(sessions) { session in
                    HStack {
                        Text(session.date.longFrenchDate)
                            .font(.footnote)
                            .foregroundStyle(Brand.textPrimary)
                        Spacer()
                        if let state = byId[session.id] {
                            BrandChip(title: state.label, tint: state.tint)
                        } else {
                            Text("Non pointé").font(.caption).foregroundStyle(Brand.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

extension AttendanceState {
    var tint: Color {
        switch self {
        case .present: Brand.success
        case .absent: Brand.error
        case .excuse: Brand.navy700
        case .retard: Brand.warning
        }
    }
}
