//
//  CoachCourseView.swift
//  iClub
//
//  Rôle
//    La fiche d'un cours, côté entraîneur : inscrits (contacts, règlement en
//    lecture seule), séances passées et à venir, écrire au groupe ou à un
//    inscrit, annuler une séance.
//
//  Place dans l'application
//    Poussée dans la pile de l'onglet « Cours » (route `CoachCourseRoute`)
//    depuis l'agenda ou la liste « Mes cours » de CoachSpaceView. Mène à
//    l'appel d'une séance (AttendanceView), à la petite fiche d'un élève
//    (StudentQuickSheet, en feuille) puis à sa fiche complète
//    (StudentDetailView), et à la feuille d'annulation d'une séance
//    (CancelSessionSheet, plus bas dans ce fichier).
//
//  Données
//    CoachStore (cours, séances, inscrits, noms), ClubCatalog (terrains).
//
//  Droits et sécurité
//    Le règlement des inscrits (`reglement` : à régler, réglé, offert) est en
//    lecture seule : c'est le club qui l'enregistre. L'annulation passe par la
//    fonction SQL `annuler_seance`, réservée à l'administrateur et à
//    l'entraîneur titulaire du cours, qui rend aussi le terrain bloqué
//    (`slot_overrides`).
//
//  Effets de bord
//    Ouverture de conversations (MessagingCenter), appels, SMS et courriels
//    par les applications d'iOS (`openURL`), annulation de séance en base.
//

import SwiftUI

/// Fiche d'un cours pour son entraîneur.
struct CoachCourseView: View {
    /// Identifiant du cours affiché (`activites.id`).
    let activityId: UUID
    /// Magasin de l'espace entraîneur.
    let store: CoachStore

    /// Catalogue du club, pour les noms des terrains.
    @Environment(ClubCatalog.self) private var catalog
    /// Messagerie, pour écrire au groupe ou à un inscrit.
    @Environment(MessagingCenter.self) private var messaging
    /// Ouverture des liens `tel:`, `sms:` et `mailto:`.
    @Environment(\.openURL) private var openURL

    /// Routeur, pour pousser la fiche complète d'un élève dans la pile.
    @Environment(AppRouter.self) private var router

    /// Séance dont la feuille d'annulation est ouverte.
    @State private var sessionToCancel: ActivitySession?
    /// Élève dont la petite fiche est ouverte.
    @State private var quickStudentId: UUID?
    /// Ouverture de la conversation de groupe en cours : bouton désactivé.
    @State private var isOpeningGroup = false

    /// Le cours, lu dans le magasin ; `nil` s'il n'est plus chargé.
    private var activity: Activity? { store.activity(id: activityId) }

    /// En-tête, inscrits et séances ; carte « Cours introuvable » si le cours
    /// a disparu du magasin.
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
                // Cours annulé ou terminé depuis : il n'est plus chargé.
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
        // Petite fiche d'un élève ; « Voir la fiche complète » pousse la fiche
        // dans la pile de l'onglet.
        .sheet(isPresented: Binding(get: { quickStudentId != nil }, set: { if !$0 { quickStudentId = nil } })) {
            if let id = quickStudentId, let enrollment = store.roster(of: activityId).first(where: { $0.id == id }) {
                StudentQuickSheet(student: StudentInfo(enrollment: enrollment, store: store)) {
                    router.activitiesPath.append(StudentRoute(enrollmentId: enrollment.id, activityId: activityId))
                }
            }
        }
        // Annulation d'une séance, puis rechargement du magasin.
        .sheet(item: $sessionToCancel) { session in
            CancelSessionSheet(session: session) {
                await store.reload()
            }
        }
    }

    // MARK: - En-tête

    /// Pastilles (type, statut, places), horaire habituel, avertissement d'un
    /// cours en attente, et bouton « Écrire au groupe ».
    /// - Parameter activity: le cours.
    /// - Returns: l'en-tête de la fiche.
    private func header(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                BrandChip(title: activity.type.singularLabel, tint: activity.sport.accent)
                // Statut : orange pour « En attente du club », vert sinon.
                BrandChip(title: activity.statut.label, tint: activity.statut == .proposee ? Brand.warning : Brand.success)
                BrandChip(title: store.placesLabel(for: activity), tint: Brand.navy700)
            }

            // Horaire habituel et terrain, si un horaire est renseigné.
            if let schedule = activity.usualSchedule {
                Text([schedule, courtName(activity.courtId)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }

            // Cours créé hors des créneaux alloués : pas encore ouvert.
            if activity.statut == .proposee {
                InlineMessage(kind: .info, message: "En attente de validation par le club : les membres ne peuvent pas encore s'inscrire.")
            }

            // Conversation de groupe du cours (créée ou complétée par
            // MessagingCenter), désactivée tant qu'il n'y a aucun inscrit.
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

    /// Carte des inscrits puis de la liste d'attente ; un tap sur une ligne
    /// ouvre la petite fiche de l'élève.
    /// - Parameter activity: le cours.
    /// - Returns: la carte « Inscrits ».
    private func rosterCard(_ activity: Activity) -> some View {
        let roster = store.roster(of: activity.id)

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inscrits")
                    .metaLabelStyle()

                // Personne d'inscrit ni en attente.
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

    /// Ligne d'un inscrit : photo, nom, rang d'attente éventuel, téléphone,
    /// courriel et commentaire saisis à l'inscription ; à droite, le règlement
    /// et le menu de contact.
    /// - Parameter enrollment: l'inscription.
    /// - Returns: la ligne.
    private func enrollmentRow(_ enrollment: ActivityEnrollment) -> some View {
        let info = enrollment.profileId.flatMap { store.people[$0] }
        let name = store.displayName(of: enrollment)

        return HStack(alignment: .top, spacing: 12) {
            // Photo du compte, sinon initiale du nom affiché.
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
                    // Liste d'attente : pastille avec le rang, s'il est connu.
                    if enrollment.statut == .listeAttente {
                        BrandChip(title: "Attente \(enrollment.rangListeAttente.map(String.init) ?? "")", tint: Brand.warning)
                            .fixedSize()
                    }
                }

                // Coordonnées et commentaire, chacun seulement s'il existe.
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
    ///
    /// Les entrées du menu dépendent de ce qui est connu : « Écrire dans
    /// l'app » s'il a un compte, « Appeler » et « Envoyer un SMS » si un
    /// téléphone a été saisi, « Envoyer un e-mail » si une adresse l'a été.
    /// - Parameters:
    ///   - enrollment: l'inscription.
    ///   - name: nom affiché, pour l'étiquette d'accessibilité.
    /// - Returns: le menu « ... ».
    private func contactMenu(_ enrollment: ActivityEnrollment, name: String) -> some View {
        // Chiffres seuls du téléphone, pour les liens `tel:` et `sms:`.
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

    /// Couleur de la pastille de règlement.
    /// - Parameter status: état du règlement (`activite_inscriptions.reglement`).
    /// - Returns: orange pour « À régler », vert pour « Réglé », bleu marine
    ///   pour « Offert ».
    private func paymentTint(_ status: PaymentStatus) -> Color {
        switch status {
        case .du: Brand.warning
        case .encaisse: Brand.success
        case .offert: Brand.navy700
        }
    }

    // MARK: - Séances

    /// Carte des séances : à venir d'abord (aujourd'hui compris, ordre
    /// chronologique), puis « Passées », de la plus récente à la plus ancienne.
    /// - Parameter activity: le cours.
    /// - Returns: la carte « Séances ».
    private func sessionsCard(_ activity: Activity) -> some View {
        let sessions = store.sessions[activity.id] ?? []
        let today = Calendar.current.startOfDay(for: .now)
        let upcoming = sessions.filter { $0.date >= today }
        let past = sessions.filter { $0.date < today }.reversed()

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Séances")
                    .metaLabelStyle()

                // Le cours n'a aucune séance (par exemple, toutes les dates
                // étaient en conflit à la création).
                if sessions.isEmpty {
                    Text("Aucune séance.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                ForEach(upcoming) { session in sessionRow(session, activity: activity, isPast: false) }

                // Séances passées, sous leur intitulé.
                if !past.isEmpty {
                    Text("Passées")
                        .metaLabelStyle()
                        .padding(.top, 6)
                    ForEach(Array(past)) { session in sessionRow(session, activity: activity, isPast: true) }
                }
            }
        }
    }

    /// Ligne d'une séance : date et horaire (barrés si annulée), terrain,
    /// remplaçant, note, motif d'annulation ; à droite, le statut et les
    /// actions permises.
    /// - Parameters:
    ///   - session: la séance.
    ///   - activity: son cours, pour reconnaître un remplaçant.
    ///   - isPast: vrai pour une séance d'un jour passé.
    /// - Returns: la ligne.
    private func sessionRow(_ session: ActivitySession, activity: Activity, isPast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(session.statut == .annulee ? Brand.textSecondary : Brand.textPrimary)
                    .strikethrough(session.statut == .annulee)

                // Terrain et remplaçant éventuels, sur une ligne.
                let details = [
                    courtName(session.courtId),
                    substitute(session, activity: activity).map { "Remplaçant : \($0)" },
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                // Note de séance, saisie à l'appel.
                if let note = session.noteSeance, !note.isEmpty {
                    Text("Note : \(note)").font(.caption).foregroundStyle(Brand.textSecondary)
                }
                // Motif d'une séance annulée.
                if session.statut == .annulee, let motif = session.motifAnnulation {
                    Text("Annulée : \(motif)").font(.caption).foregroundStyle(Brand.error)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                BrandChip(title: session.statut.label, tint: statusTint(session.statut))
                    .fixedSize()

                // Appel : pour une séance passée ou du jour, ni annulée ni
                // reportée ; « Appel » pour revoir un appel fait.
                if session.statut != .annulee && session.statut != .reportee && (isPast || session.isToday) {
                    NavigationLink(value: AttendanceRoute(sessionId: session.id)) {
                        Text(session.statut == .faite ? "Appel" : "Faire l'appel")
                            .font(.caption.weight(.semibold))
                    }
                }
                // Annulation : seulement pour une séance prévue, pas passée
                // (celle du jour comprise).
                if session.statut == .prevue && !isPast {
                    Button("Annuler", role: .destructive) { sessionToCancel = session }
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    /// Couleur de la pastille de statut d'une séance.
    /// - Parameter status: statut (`activite_seances.statut`).
    /// - Returns: bleu marine (prévue), vert (faite), rouge (annulée), orange
    ///   (reportée).
    private func statusTint(_ status: SessionStatus) -> Color {
        switch status {
        case .prevue: Brand.navy700
        case .faite: Brand.success
        case .annulee: Brand.error
        case .reportee: Brand.warning
        }
    }

    /// Remplaçant d'une séance, s'il diffère de l'entraîneur habituel.
    /// - Parameters:
    ///   - session: la séance.
    ///   - activity: son cours.
    /// - Returns: le nom du remplaçant, ou `nil`.
    private func substitute(_ session: ActivitySession, activity: Activity) -> String? {
        guard let id = session.entraineurProfileId, id != activity.entraineurProfileId else { return nil }
        return store.people[id]?.displayName
    }

    /// Nom d'un terrain du catalogue du club.
    /// - Parameter id: identifiant du terrain, ou `nil`.
    /// - Returns: son nom, ou `nil` s'il est absent ou inconnu.
    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }
}

// MARK: - Annuler une séance

/// Le motif est obligatoire : les inscrits le liront.
///
/// Feuille présentée depuis la fiche d'un cours ou depuis l'appel. Elle appelle
/// la fonction SQL `annuler_seance` (CoachService.cancelSession), qui passe la
/// séance en `annulee` avec son motif et supprime le blocage du terrain
/// (`slot_overrides`) : le créneau redevient réservable. L'app impose un motif
/// non vide ; la fonction, elle, en accepte un absent (« Séance annulée »).
///
/// Attention : à la date de cette passe, aucun écran membre ne montre ce motif
/// (ni dans l'app, où une séance annulée disparaît simplement de la liste des
/// séances à venir, ni dans l'espace membre du web) ; il est lu par
/// l'entraîneur et par le club. L'app n'envoie pas non plus de message aux
/// inscrits, et la fonction SQL non plus.
struct CancelSessionSheet: View {
    /// La séance à annuler.
    let session: ActivitySession
    /// Appelée après une annulation réussie, avant la fermeture (rechargement
    /// du magasin).
    let onCancelled: () async -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Motif saisi.
    @State private var motif = ""
    /// Annulation en cours : bouton désactivé.
    @State private var isWorking = false
    /// Message d'échec affiché dans le formulaire.
    @State private var errorMessage: String?

    /// Motif sans blancs autour, qui doit être non vide.
    private var trimmedMotif: String { motif.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Formulaire : la séance, le motif, l'erreur éventuelle ; « Retour » et
    /// « Annuler la séance » dans la barre.
    var body: some View {
        NavigationStack {
            Form {
                // Rappel de la séance visée.
                Section {
                    Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                        .font(.subheadline.weight(.medium))
                } footer: {
                    Text("Le terrain est rendu à la réservation.")
                }

                // Motif libre, sur deux à quatre lignes.
                Section("Motif") {
                    TextField("Pluie, entraîneur malade…", text: $motif, axis: .vertical)
                        .lineLimit(2...4)
                }

                // Refus ou échec de la base.
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
                // Désactivé sans motif ou pendant l'envoi.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Annuler la séance", role: .destructive) { cancel() }
                        .disabled(trimmedMotif.isEmpty || isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Envoie l'annulation ; en cas de succès, vibration sèche, rechargement
    /// par l'appelant puis fermeture ; sinon message dans le formulaire.
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
