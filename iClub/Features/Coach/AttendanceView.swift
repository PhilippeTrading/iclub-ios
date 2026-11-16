//
//  AttendanceView.swift
//  iClub
//
//  Rôle
//    L'appel d'une séance. Un tap change l'état d'un élève et l'écrit tout de
//    suite : pas de bouton « Enregistrer ». Quand tout le monde est pointé, la
//    séance passe en « faite ».
//
//    La note de séance porte sur le groupe, jamais sur un élève.
//
//  Place dans l'application
//    Poussé dans la pile de l'onglet « Cours » (route `AttendanceRoute`) depuis
//    l'agenda de la semaine, depuis la fiche d'un cours, ou directement par le
//    tap sur le rappel local « Faire l'appel » (AttendanceReminders, ouvert par
//    MainTabView). Mène à la petite fiche d'un élève et à l'annulation de la
//    séance.
//
//  Données et écritures (CoachService)
//    - lecture : table `activite_presences` de la séance ;
//    - pointage : upsert dans `activite_presences` sur la paire (séance,
//      inscription), avec `saisie_par` = l'utilisateur ; la RLS
//      « presences_ecriture » le réserve à l'administrateur et à l'entraîneur
//      titulaire du cours ;
//    - fin de l'appel : `activite_seances.statut` passe de `prevue` à `faite` ;
//    - note : `activite_seances.note_seance`, enregistrée en quittant le champ
//      ou l'écran.
//    Les élèves pointés sont les inscrits (`statut = inscrit`), pas la liste
//    d'attente. Le web fait le même travail en un seul appel, par la fonction
//    SQL `enregistrer_appel` ; l'app écrit en deux temps.
//
//  États
//    Message d'erreur en ligne (lecture ou écriture refusée), « Aucun inscrit à
//    pointer. », sinon une carte par élève. Le bouton « Tous présents » attend
//    la fin de la lecture des présences.
//
//  Points d'attention
//    - Écriture optimiste : l'écran change tout de suite et revient à l'état
//      précédent si la base refuse.
//    - Attention : si les présences s'écrivent mais que le passage de la séance
//      en « faite » échoue, l'écran revient lui aussi à l'état précédent, alors
//      que les présences sont bien enregistrées en base (elles réapparaissent
//      à la prochaine ouverture).
//    - « Tous présents » remplace aussi les absences déjà pointées.
//

import SwiftUI

/// Écran d'appel d'une séance.
struct AttendanceView: View {
    /// Identifiant de la séance (`activite_seances.id`).
    let sessionId: UUID
    /// Magasin de l'espace entraîneur.
    let store: CoachStore

    /// Session : profil de l'entraîneur (`saisie_par`, chargement de secours).
    @Environment(AuthController.self) private var auth
    /// Routeur, pour pousser la fiche complète d'un élève.
    @Environment(AppRouter.self) private var router

    /// État de présence connu, par inscription (`activite_inscriptions.id`).
    /// Absent du dictionnaire : élève pas encore pointé.
    @State private var states: [UUID: AttendanceState] = [:]
    /// Note de séance en cours de saisie.
    @State private var note = ""
    /// Dernière note enregistrée, pour n'écrire qu'en cas de changement.
    @State private var savedNote = ""
    /// Lecture des présences terminée (avec ou sans erreur).
    @State private var isLoaded = false
    /// Message d'erreur en ligne (lecture, pointage ou note).
    @State private var errorMessage: String?
    /// Confirmation discrète sous la note (« Note enregistrée. »).
    @State private var noteStatus: String?
    /// Feuille d'annulation de la séance ouverte.
    @State private var showsCancel = false
    /// Élève dont la petite fiche est ouverte.
    @State private var quickStudentId: UUID?
    /// Élève pour qui l'on précise « à l'heure » ou « en retard ».
    @State private var punctualityFor: UUID?
    /// Focus clavier du champ de note.
    @FocusState private var noteFocused: Bool

    /// La séance, lue dans le magasin.
    private var session: ActivitySession? { store.session(id: sessionId) }
    /// Le cours de la séance.
    private var activity: Activity? { session.flatMap { store.activity(id: $0.activiteId) } }
    /// Les élèves à pointer : les inscrits du cours, sans la liste d'attente.
    private var enrolled: [ActivityEnrollment] {
        guard let session else { return [] }
        return store.enrolled(in: session.activiteId)
    }

    /// En-tête, note, erreur éventuelle et liste des élèves ; menu « ... »
    /// d'annulation dans la barre.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Rien tant que la séance n'est pas dans le magasin (chargement
                // de secours en cours, ou séance inconnue).
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
            // Menu « ... » : annuler la séance, seulement tant qu'elle est
            // prévue (désactivé sinon).
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
        // Feuille d'annulation (CoachCourseView.swift), puis rechargement.
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

    /// Nom du cours, date et horaire, bouton « Tous présents » et compteur de
    /// pointage.
    /// - Parameter session: la séance.
    /// - Returns: l'en-tête.
    private func header(_ session: ActivitySession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(activity?.nom ?? "Séance")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)
            Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            HStack {
                // Désactivé avant la lecture des présences, ou sans inscrit.
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

    /// « 3 / 8 pointés » : élèves inscrits qui ont un état, sur le nombre
    /// d'inscrits.
    private var progressLabel: String {
        let done = enrolled.filter { states[$0.id] != nil }.count
        return "\(done) / \(enrolled.count) pointés"
    }

    // MARK: - Note de séance

    /// Carte de la note de séance, sur deux à cinq lignes, avec la
    /// confirmation d'enregistrement.
    private var noteCard: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Note de séance")
                    .metaLabelStyle()
                TextField("Travail du service, séance écourtée par la pluie…", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($noteFocused)
                    .submitLabel(.done)
                // « Note enregistrée. » après une écriture réussie.
                if let noteStatus {
                    Text(noteStatus)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    // MARK: - Élèves

    /// Les cartes des élèves inscrits, ou une phrase s'il n'y en a aucun.
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
    ///
    /// « Présent » est allumé pour présent et retard, « Absent » pour absent et
    /// excusé (l'état « excusé » ne se pose pas depuis l'app, mais il s'affiche
    /// s'il a été saisi ailleurs).
    /// - Parameter enrollment: l'inscription de l'élève.
    /// - Returns: la carte de l'élève.
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
                            // État pointé, en clair et en couleur.
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

    /// Libellé de l'état sous le nom de l'élève.
    /// - Parameter state: état de présence.
    /// - Returns: « Présent, à l'heure », « Présent, en retard », « Absent » ou
    ///   « Absent, excusé ».
    private func statusLine(_ state: AttendanceState) -> String {
        switch state {
        case .present: "Présent, à l'heure"
        case .retard: "Présent, en retard"
        case .absent: "Absent"
        case .excuse: "Absent, excusé"
        }
    }

    /// Bouton de choix pleine largeur : plein de sa couleur quand il est
    /// choisi, teinté à 10 % sinon.
    /// - Parameters:
    ///   - title: texte du bouton.
    ///   - systemImage: symbole SF Symbols.
    ///   - tint: couleur du bouton.
    ///   - isSelected: état allumé.
    ///   - action: action à l'appui.
    /// - Returns: le bouton.
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

    /// Ouvre le panneau « À l'heure / En retard » pour un seul élève à la fois.
    /// - Parameter id: identifiant de l'inscription de l'élève.
    /// - Returns: le lien d'ouverture du panneau.
    private func punctualityBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { punctualityFor == id }, set: { if !$0 { punctualityFor = nil } })
    }

    // MARK: - Écritures

    /// Reprend la note de la séance et lit ses présences déjà pointées.
    private func load() async {
        guard let session else { return }
        note = session.noteSeance ?? ""
        savedNote = note
        do {
            let rows = try await CoachService.attendance(sessionId: session.id)
            // Une présence par inscription ; en cas de doublon, la dernière lue.
            states = Dictionary(rows.map { ($0.inscriptionId, $0.etat) }, uniquingKeysWith: { _, last in last })
        } catch {
            errorMessage = ActivityServiceError.from(error).localizedDescription
        }
        isLoaded = true
    }

    /// Pose un état pour un élève, s'il change.
    /// - Parameters:
    ///   - state: nouvel état.
    ///   - enrollment: l'inscription de l'élève.
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
    ///
    /// Une fois les présences écrites, si tous les inscrits ont un état et que
    /// la séance était prévue, elle passe en « faite » et le magasin est
    /// rechargé (pastille « Appel fait » dans l'agenda).
    /// - Parameter changes: nouveaux états, par inscription.
    private func write(_ changes: [UUID: AttendanceState]) {
        guard let session else { return }
        // État d'avant, pour revenir en arrière en cas d'échec.
        let previous = states
        states.merge(changes) { _, new in new }
        errorMessage = nil

        let rows = changes.map {
            AttendanceRow(seanceId: session.id, inscriptionId: $0.key, etat: $0.value, saisiePar: auth.sessionProfile?.id)
        }

        Task {
            do {
                try await CoachService.setAttendance(rows)
                // Appel complet : séance « faite » (écriture limitée aux
                // séances encore prévues, voir CoachService).
                if enrolled.allSatisfy({ states[$0.id] != nil }), session.statut == .prevue {
                    try await CoachService.markSessionDone(session.id)
                    await store.reload()
                }
            } catch {
                // Retour à l'état d'avant, avec le message de la base.
                states = previous
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    /// Enregistre la note si elle a changé (vide : la note est effacée), puis
    /// recharge le magasin pour que la fiche du cours la montre.
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
/// défaut, et « Fermer » en haut à droite, comme le menu déroulant d'iOS.
///
/// Chaque cran de la roue écrit aussitôt l'état (présent ou retard) par
/// `onChange` ; « Fermer » ne fait que refermer le panneau.
private struct PunctualitySheet: View {
    /// Position de la roue : vrai pour « En retard ». Initialisée avec l'état
    /// courant de l'élève.
    @State var isLate: Bool
    /// Appelée à chaque changement de la roue, avec la nouvelle valeur.
    let onChange: (Bool) -> Void

    /// Fermeture du panneau.
    @Environment(\.dismiss) private var dismiss

    /// Titre « Présent » et bouton « Fermer », puis la roue.
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
        // Panneau bas de 260 points, sans poignée.
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.hidden)
        .onChange(of: isLate) { _, late in
            onChange(late)
        }
    }
}
