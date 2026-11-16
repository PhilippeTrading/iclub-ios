//
//  StudentViews.swift
//  iClub
//
//  Rôle
//    Un élève, vu par son entraîneur : la petite fiche qui s'ouvre par-dessus
//    l'appel, et la fiche complète.
//
//    Le téléphone est celui donné à l'inscription, souvent celui d'un parent
//    pour un enfant.
//
//  Place dans l'application
//    - StudentQuickSheet : feuille ouverte depuis l'appel (AttendanceView) ou
//      la fiche d'un cours (CoachCourseView) ; son bouton « Voir la fiche
//      complète » pousse la route `StudentRoute` dans la pile de l'onglet
//      « Cours ».
//    - StudentDetailView : la fiche complète, reliée à `StudentRoute` par
//      `coachDestinations` (CoachSpaceView.swift).
//
//  Données
//    L'inscription (`activite_inscriptions` : nom affiché, téléphone,
//    courriel, commentaire, règlement), le profil s'il existe
//    (`get_club_roster_info` : photo, âge), et le relevé de présence de
//    l'élève (`activite_presences`, lu par CoachService.attendanceHistory ;
//    la RLS le réserve à l'élève, à l'administrateur et à l'entraîneur du
//    cours).
//
//  Points d'attention
//    - Limite connue : la fonction `get_club_roster_info` ne renvoie plus la
//      date de naissance depuis la migration 20260924110000 (seulement l'âge).
//      `birthDate` reste donc vide : « Date de naissance » affiche toujours
//      « Non renseignée » et la ligne d'identité ne montre que l'âge.
//    - « né le » ne s'accorde pas au féminin.
//

import SwiftUI

/// Fiche complète d'un élève, poussée dans la pile de l'onglet.
struct StudentRoute: Hashable {
    /// Identifiant de l'inscription (`activite_inscriptions.id`).
    let enrollmentId: UUID
    /// Identifiant du cours (`activites.id`).
    let activityId: UUID
}

// MARK: - Informations communes

/// Ce qu'on sait d'un élève : son inscription, et son profil s'il a un compte.
struct StudentInfo {
    /// L'inscription au cours.
    let enrollment: ActivityEnrollment
    /// Nom affiché (voir CoachStore.displayName).
    let name: String
    /// Profil retrouvé par `get_club_roster_info` ; `nil` sans compte (ou nom
    /// non chargé).
    let profile: RosterInfoRow?

    /// Réunit l'inscription et ce que le magasin sait du profil.
    /// - Parameters:
    ///   - enrollment: l'inscription.
    ///   - store: le magasin de l'entraîneur.
    init(enrollment: ActivityEnrollment, store: CoachStore) {
        self.enrollment = enrollment
        self.name = store.displayName(of: enrollment)
        self.profile = enrollment.profileId.flatMap { store.people[$0] }
    }

    /// Adresse de la photo du profil, si elle existe.
    var avatarURL: URL? { profile?.avatarUrl.flatMap(URL.init(string:)) }

    /// Initiales du profil, sinon celles des deux premiers mots du nom
    /// affiché, sinon « ? ».
    var initials: String {
        if let profile { return profile.initials }
        let value = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    /// Date de naissance du profil. Toujours `nil` aujourd'hui (voir la limite
    /// connue en tête de fichier).
    var birthDate: Date? { SupabaseDate.parse(profile?.dateNaissance) }

    /// Âge en années : celui calculé par la base, sinon déduit de la date de
    /// naissance.
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
    /// Séances où l'élève était là (présent ou en retard).
    let present: Int
    /// Parmi elles, celles où il était en retard.
    let late: Int
    /// Séances manquées (absent ou excusé).
    let absent: Int

    /// Compte les états d'une liste de présences.
    /// - Parameter rows: présences de l'élève (`activite_presences`).
    init(_ rows: [AttendanceRow]) {
        present = rows.filter { $0.etat == .present || $0.etat == .retard }.count
        late = rows.filter { $0.etat == .retard }.count
        absent = rows.filter { $0.etat == .absent || $0.etat == .excuse }.count
    }
}

// MARK: - Boutons de contact

/// « Appeler » et « SMS » vers le téléphone saisi à l'inscription, ou une
/// phrase s'il n'y en a pas.
private struct ContactButtons: View {
    /// L'élève.
    let student: StudentInfo
    /// Ouverture des liens `tel:` et `sms:` par iOS.
    @Environment(\.openURL) private var openURL

    /// Deux boutons côte à côte, ou la phrase d'absence de téléphone.
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

    /// Bouton en verre qui ouvre un lien.
    /// - Parameters:
    ///   - title: texte du bouton.
    ///   - systemImage: symbole SF Symbols.
    ///   - url: lien à ouvrir (`tel:` ou `sms:`).
    /// - Returns: le bouton.
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

/// Deux compteurs côte à côte : présences (avec le nombre de retards) et
/// absences.
private struct AttendanceCounters: View {
    /// Relevé ; `nil` tant qu'il n'est pas chargé (les compteurs affichent un
    /// tiret).
    let summary: AttendanceSummary?

    /// Compteur vert des présences, compteur rouge des absences.
    var body: some View {
        HStack(spacing: 10) {
            counter("Présences", value: summary?.present, tint: Brand.success,
                    detail: summary.map { $0.late > 0 ? "dont \($0.late) retard\($0.late > 1 ? "s" : "")" : nil } ?? nil)
            counter("Absences", value: summary?.absent, tint: Brand.error, detail: nil)
        }
    }

    /// Un compteur : grand chiffre, intitulé, détail facultatif.
    /// - Parameters:
    ///   - title: intitulé sous le chiffre.
    ///   - value: valeur, ou `nil` pendant le chargement (tiret affiché).
    ///   - tint: couleur du chiffre et du fond (à 8 %).
    ///   - detail: ligne de détail, ou `nil`.
    /// - Returns: le compteur.
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
///
/// Grande photo, nom, âge, boutons de contact, compteurs de présence et lien
/// vers la fiche complète. Le relevé est lu à l'ouverture ; en cas d'échec, les
/// compteurs restent sur un tiret.
struct StudentQuickSheet: View {
    /// L'élève.
    let student: StudentInfo
    /// Appelée après fermeture de la feuille, pour pousser la fiche complète.
    let onOpenFullSheet: () -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Relevé de présence, une fois chargé.
    @State private var summary: AttendanceSummary?

    /// Contenu de la feuille, dans sa propre pile de navigation (bouton
    /// « Fermer »).
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Identité.
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

                    // La feuille se ferme d'abord, puis l'appelant pousse la
                    // fiche complète dans la pile de l'onglet.
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
        // Relevé de présence de l'élève, toutes séances du cours confondues.
        .task {
            if let rows = try? await CoachService.attendanceHistory(inscriptionId: student.enrollment.id) {
                summary = AttendanceSummary(rows)
            }
        }
    }

    /// « 11 ans · né le 3 mars 2015 ».
    ///
    /// L'âge et la date de naissance, chacun s'il est connu ; « Âge non
    /// renseigné » sinon.
    private var identityLine: String {
        var parts: [String] = []
        if let age = student.age { parts.append("\(age) ans") }
        if let birth = student.birthDate { parts.append("né le \(birth.frenchDayMonthYear)") }
        return parts.isEmpty ? "Âge non renseigné" : parts.joined(separator: " · ")
    }
}

// MARK: - Fiche complète

/// Fiche complète d'un élève : identité, informations d'inscription, contacts,
/// compteurs et relevé séance par séance.
struct StudentDetailView: View {
    /// L'inscription et le cours visés.
    let route: StudentRoute
    /// Magasin de l'espace entraîneur.
    let store: CoachStore

    /// Messagerie, pour écrire à un élève qui a un compte.
    @Environment(MessagingCenter.self) private var messaging
    /// Ouverture du lien `mailto:`.
    @Environment(\.openURL) private var openURL
    /// Présences de l'élève, chargées à l'ouverture.
    @State private var history: [AttendanceRow] = []
    /// Relevé chargé (vide en cas d'échec).
    @State private var isLoaded = false

    /// L'inscription, relue dans le magasin ; `nil` si l'élève n'y figure plus.
    private var enrollment: ActivityEnrollment? {
        store.enrollments[route.activityId]?.first { $0.id == route.enrollmentId }
    }

    /// La fiche, ou une carte « Élève introuvable » si l'inscription a disparu
    /// (désinscription, cours annulé).
    var body: some View {
        ScrollView {
            if let enrollment {
                let student = StudentInfo(enrollment: enrollment, store: store)
                VStack(alignment: .leading, spacing: 16) {
                    // Photo, nom et cours.
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
                    // « Écrire » et « E-mail », si l'élève a un compte ou une
                    // adresse saisie.
                    if enrollment.profileId != nil || enrollment.email != nil {
                        moreContacts(student)
                    }
                    // Compteurs : tirets tant que le relevé n'est pas chargé.
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
        // Relevé de présence ; un échec donne un relevé vide.
        .task {
            history = (try? await CoachService.attendanceHistory(inscriptionId: route.enrollmentId)) ?? []
            isLoaded = true
        }
    }

    /// Carte « Informations » : âge, date de naissance, téléphone, courriel,
    /// état de l'inscription, règlement (lecture seule) et commentaire.
    /// - Parameter student: l'élève.
    /// - Returns: la carte.
    private func infoCard(_ student: StudentInfo) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                ProfileCardHeader(title: "Informations")
                LabeledContent("Âge", value: student.age.map { "\($0) ans" } ?? "Non renseigné")
                LabeledContent("Date de naissance", value: student.birthDate?.frenchDayMonthYear ?? "Non renseignée")
                LabeledContent("Téléphone", value: PhoneNumber.formattedForDisplay(student.enrollment.telephone) ?? "Non renseigné")
                // Courriel saisi à l'inscription, coupé au milieu s'il est long.
                if let email = student.enrollment.email, !email.isEmpty {
                    LabeledContent("E-mail") {
                        Text(email).lineLimit(1).truncationMode(.middle)
                    }
                }
                LabeledContent("Inscription", value: student.enrollment.statut == .listeAttente ? "Liste d'attente" : "Inscrit")
                LabeledContent("Règlement", value: student.enrollment.reglement.label)
                // Commentaire laissé à l'inscription.
                if let comment = student.enrollment.commentaire, !comment.isEmpty {
                    Text(comment).font(.footnote).italic().foregroundStyle(Brand.textSecondary)
                }
            }
            .font(.subheadline)
        }
    }

    /// Boutons « Écrire » (conversation dans l'app, si l'élève a un compte) et
    /// « E-mail » (si une adresse a été saisie).
    /// - Parameter student: l'élève.
    /// - Returns: la rangée de boutons.
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
    ///
    /// Séances retenues : celles d'aujourd'hui ou avant, plus celles déjà
    /// pointées, hors séances annulées. Chaque ligne montre l'état pointé, ou
    /// « Non pointé ».
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
                // Aucune séance encore passée.
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

/// Couleur de chaque état de présence (le modèle est dans CoachService.swift).
extension AttendanceState {
    /// Couleur d'un état de présence : vert (présent), rouge (absent), bleu
    /// marine (excusé), orange (retard). Partagée par l'appel et les fiches.
    var tint: Color {
        switch self {
        case .present: Brand.success
        case .absent: Brand.error
        case .excuse: Brand.navy700
        case .retard: Brand.warning
        }
    }
}
