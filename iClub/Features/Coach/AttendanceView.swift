//
//  AttendanceView.swift
//  iClub
//
//  L'appel d'une séance. Un tap change l'état d'un élève et l'écrit tout de
//  suite : pas de bouton « Enregistrer ». Quand tout le monde est pointé, la
//  séance passe en « faite ».
//
//  La note de séance porte sur le groupe, jamais sur un élève.
//

import SwiftUI

struct AttendanceView: View {
    let sessionId: UUID
    let store: CoachStore

    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var states: [UUID: AttendanceState] = [:]
    @State private var note = ""
    @State private var savedNote = ""
    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var noteStatus: String?
    @State private var showsCancel = false
    /// Élève dont la petite fiche est ouverte.
    @State private var quickStudentId: UUID?
    /// Élève pour qui l'on précise « à l'heure » ou « en retard ».
    @State private var punctualityFor: UUID?
    @FocusState private var noteFocused: Bool

    private var session: ActivitySession? { store.session(id: sessionId) }
    private var activity: Activity? { session.flatMap { store.activity(id: $0.activiteId) } }
    private var enrolled: [ActivityEnrollment] {
        guard let session else { return [] }
        return store.enrolled(in: session.activiteId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let session {
                    header(session)
                    noteCard
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }
                    list
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Appel")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if session?.statut == .prevue {
                        Button("Annuler la séance", systemImage: "xmark.circle", role: .destructive) {
                            showsCancel = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(session?.statut != .prevue)
            }
        }
        .sheet(isPresented: $showsCancel) {
            if let session {
                CancelSessionSheet(session: session) { await store.reload() }
            }
        }
        .task(id: sessionId) {
            // Ouvert depuis le rappel, l'onglet n'a peut-être pas encore chargé
            // les cours de l'entraîneur.
            if store.session(id: sessionId) == nil, let profile = auth.sessionProfile {
                await store.load(clubId: profile.clubId, coachId: profile.id)
            }
            await load()
        }
        // La petite fiche s'ouvre par-dessus l'appel, sans le quitter.
        .sheet(isPresented: Binding(get: { quickStudentId != nil }, set: { if !$0 { quickStudentId = nil } })) {
            if let id = quickStudentId, let enrollment = enrolled.first(where: { $0.id == id }), let session {
                StudentQuickSheet(student: StudentInfo(enrollment: enrollment, store: store)) {
                    router.activitiesPath.append(StudentRoute(enrollmentId: enrollment.id, activityId: session.activiteId))
                }
            }
        }
        // Enregistrée en quittant le champ, ou l'écran.
        .onChange(of: noteFocused) { _, focused in
            if !focused { saveNote() }
        }
        .onDisappear { saveNote() }
    }

    // MARK: - En-tête

    private func header(_ session: ActivitySession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(activity?.nom ?? "Séance")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)
            Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            HStack {
                Button {
                    markAllPresent()
                } label: {
                    Label("Tous présents", systemImage: "checkmark.circle.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.success)
                .disabled(!isLoaded || enrolled.isEmpty)

                Spacer()

                Text(progressLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    private var progressLabel: String {
        let done = enrolled.filter { states[$0.id] != nil }.count
        return "\(done) / \(enrolled.count) pointés"
    }

    // MARK: - Note de séance

    private var noteCard: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Note de séance")
                    .metaLabelStyle()
                TextField("Travail du service, séance écourtée par la pluie…", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($noteFocused)
                    .submitLabel(.done)
                if let noteStatus {
                    Text(noteStatus)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    // MARK: - Élèves

    @ViewBuilder
    private var list: some View {
        if enrolled.isEmpty {
            Text("Aucun inscrit à pointer.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
        } else {
            VStack(spacing: 10) {
                ForEach(enrolled) { enrollment in
                    studentRow(enrollment)
                }
            }
        }
    }

    /// Haut de la vignette (photo, nom) : ouvre la petite fiche. Dessous, deux
    /// boutons sur toute la largeur : Présent, Absent.
    private func studentRow(_ enrollment: ActivityEnrollment) -> some View {
        let current = states[enrollment.id]
        let student = StudentInfo(enrollment: enrollment, store: store)
        let isPresent = current == .present || current == .retard
        let isAbsent = current == .absent || current == .excuse

        return SurfaceCard(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    quickStudentId = enrollment.id
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: student.avatarURL, initials: student.initials, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(student.name)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            if let current {
                                Text(statusLine(current))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(current.tint)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "info.circle")
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvre la fiche de l'élève")

                HStack(spacing: 8) {
                    choiceButton("Présent", systemImage: "checkmark", tint: Brand.success, isSelected: isPresent) {
                        // Présent d'abord à l'heure ; la petite fenêtre permet de
                        // préciser un retard.
                        if !isPresent { set(.present, for: enrollment) }
                        punctualityFor = enrollment.id
                    }
                    // Panneau bas avec roue, comme un menu déroulant iOS.
                    .sheet(isPresented: punctualityBinding(enrollment.id)) {
                        PunctualitySheet(isLate: current == .retard) { late in
                            set(late ? .retard : .present, for: enrollment)
                        }
                    }

                    choiceButton("Absent", systemImage: "xmark", tint: Brand.error, isSelected: isAbsent) {
                        set(.absent, for: enrollment)
                    }
                }
            }
        }
    }

    private func statusLine(_ state: AttendanceState) -> String {
        switch state {
        case .present: "Présent, à l'heure"
        case .retard: "Présent, en retard"
        case .absent: "Absent"
        case .excuse: "Absent, excusé"
        }
    }

    private func choiceButton(_ title: String, systemImage: String, tint: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(isSelected ? Color.white : tint)
                .background(isSelected ? tint : tint.opacity(0.1), in: .rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func punctualityBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { punctualityFor == id }, set: { if !$0 { punctualityFor = nil } })
    }

    // MARK: - Écritures

    private func load() async {
        guard let session else { return }
        note = session.noteSeance ?? ""
        savedNote = note
        do {
            let rows = try await CoachService.attendance(sessionId: session.id)
            states = Dictionary(rows.map { ($0.inscriptionId, $0.etat) }, uniquingKeysWith: { _, last in last })
        } catch {
            errorMessage = ActivityServiceError.from(error).localizedDescription
        }
        isLoaded = true
    }

    private func set(_ state: AttendanceState, for enrollment: ActivityEnrollment) {
        guard states[enrollment.id] != state else { return }
        Haptics.selection()
        write([enrollment.id: state])
    }

    /// Pose « présent » sur tout le monde ; on corrige ensuite les exceptions.
    private func markAllPresent() {
        Haptics.success()
        write(Dictionary(enrolled.map { ($0.id, AttendanceState.present) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Optimiste : l'état change à l'écran, et revient en arrière si la base
    /// refuse.
    private func write(_ changes: [UUID: AttendanceState]) {
        guard let session else { return }
        let previous = states
        states.merge(changes) { _, new in new }
        errorMessage = nil

        let rows = changes.map {
            AttendanceRow(seanceId: session.id, inscriptionId: $0.key, etat: $0.value, saisiePar: auth.sessionProfile?.id)
        }

        Task {
            do {
                try await CoachService.setAttendance(rows)
                if enrolled.allSatisfy({ states[$0.id] != nil }), session.statut == .prevue {
                    try await CoachService.markSessionDone(session.id)
                    await store.reload()
                }
            } catch {
                states = previous
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    private func saveNote() {
        guard note != savedNote else { return }
        let value = note
        Task {
            do {
                try await CoachService.saveNote(value, sessionId: sessionId)
                savedNote = value
                noteStatus = "Note enregistrée."
                await store.reload()
            } catch {
                noteStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - À l'heure ou en retard

/// Le panneau qui suit « Présent » : une roue « Statut », « À l'heure » par
/// défaut, et « Fermer » en haut à droite — le menu déroulant d'iOS.
private struct PunctualitySheet: View {
    @State var isLate: Bool
    let onChange: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Présent")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                Button("Fermer") { dismiss() }
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Picker("Statut", selection: $isLate) {
                Text("À l'heure").tag(false)
                Text("En retard").tag(true)
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.hidden)
        .onChange(of: isLate) { _, late in
            onChange(late)
        }
    }
}
