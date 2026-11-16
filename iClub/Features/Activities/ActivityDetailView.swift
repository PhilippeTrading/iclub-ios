//
//  ActivityDetailView.swift
//  iClub
//
//  Rôle
//    Détail d'une activité, côté membre : description, séances à venir, règles,
//    tarif, entraîneur, et inscription.
//
//  Place dans l'application
//    Poussé dans la pile de l'onglet « Cours » par un tap sur une carte (route
//    `ActivityRoute`, déclarée dans ActivitiesView). L'écran lit l'activité,
//    ses séances et les inscriptions dans l'ActivitiesStore de la liste, qu'il
//    recharge après chaque inscription ou désinscription : la liste se met à
//    jour en même temps.
//
//  Règles métier
//    L'inscription passe par `inscrire_activite`, qui tranche tout : inscrit ou
//    liste d'attente, refus d'âge ou de niveau, fenêtre fermée. L'app ne fait
//    qu'afficher la réponse.
//    La désinscription passe par `desinscrire_activite`, qui fait monter le
//    premier de la liste d'attente sur la place libérée (ou rouvre l'activité
//    si personne n'attendait).
//    « Pour qui ? » : le membre peut s'inscrire lui-même, ou inscrire un enfant
//    dont il a la charge avec le droit d'inscription aux activités (fonction
//    `mes_profils_geres`, colonne `peut_inscrire_activites` de `liens_famille`).
//
//  Droits et sécurité
//    Les deux fonctions SQL sont `security definer` et vérifient elles-mêmes
//    l'appartenance au club, le statut, la fenêtre d'inscription, l'âge, le
//    niveau, les places, et le droit d'agir pour un enfant (`peut_agir_pour`).
//    Leurs refus arrivent en code P0001 avec un message en français, affiché
//    tel quel (migrations 20261018160000_comptes_famille et
//    20261018170000_correctif_inscrire_activite).
//
//  Effets de bord
//    Écriture dans `activite_inscriptions` par les fonctions SQL, qui passent
//    aussi l'activité en `complete` (dernière place prise) ou la rouvrent en
//    `ouverte` (place libérée sans liste d'attente). Vibration de succès ou
//    d'échec. La bulle de messagerie est masquée tant que l'écran est affiché.
//
//  Points d'attention
//    - Attention : la liste des personnes (`managedProfiles`) se charge à
//      l'ouverture de l'écran. Un appui sur « S'inscrire » avant la fin de ce
//      chargement, ou quand l'enfant choisi en haut n'a pas le droit
//      d'inscription et que le membre est seul éligible, inscrit le membre
//      lui-même (`enroll(nil)`), même si un enfant est sélectionné en haut.
//    - Limite connue : quand le parent agit pour un enfant, l'inscription de
//      l'enfant n'est pas lisible (voir ActivitiesStore) ; la barre du bas
//      propose donc « S'inscrire » même s'il est déjà inscrit, et la base
//      répond « Déjà inscrit ».
//    - Le message d'échec générique tutoie (« Impossible de t'inscrire pour
//      l'instant. »), alors que l'app vouvoie partout ailleurs.
//    - Un échec de désinscription s'affiche aussi sous le titre « Inscription
//      impossible ».
//

import SwiftUI

/// Écran de détail d'une activité et d'inscription, côté membre.
struct ActivityDetailView: View {
    /// Identifiant de l'activité affichée (`activites.id`).
    let activityId: UUID
    /// Magasin partagé avec la liste de l'onglet « Cours ».
    let store: ActivitiesStore

    /// Session : club du membre, profil actif (lui-même ou un enfant).
    @Environment(AuthController.self) private var auth
    /// Catalogue du club, pour les noms des terrains.
    @Environment(ClubCatalog.self) private var catalog
    /// Messagerie, pour écrire à l'entraîneur.
    @Environment(MessagingCenter.self) private var messaging

    /// Le membre et les enfants dont il a la charge (`mes_profils_geres`),
    /// chargés à l'ouverture de l'écran.
    @State private var managedProfiles: [ManagedProfile] = []
    /// Fenêtre « Inscrire qui ? » ouverte.
    @State private var isChoosingPerson = false
    /// Inscription ou désinscription en cours : boutons désactivés.
    @State private var isWorking = false
    /// Fenêtre de confirmation « Se désinscrire ? » ouverte.
    @State private var confirmUnenroll = false
    /// Titre et texte de l'alerte de résultat d'une inscription réussie.
    @State private var resultMessage: (title: String, message: String)?
    /// Message de l'alerte d'échec (inscription ou désinscription).
    @State private var errorMessage: String?

    /// L'activité, lue dans le magasin ; `nil` si elle n'est plus publiée.
    private var activity: Activity? { store.activity(id: activityId) }

    /// Le contenu, ou une carte « Plus proposé » si l'activité a disparu du
    /// magasin (annulée, terminée ou retirée depuis la liste), avec les
    /// fenêtres de choix, de confirmation et d'alerte.
    var body: some View {
        Group {
            if let activity {
                content(activity)
            } else {
                // Activité absente du magasin rechargé.
                PhasePlaceholder(
                    systemImage: "calendar.badge.exclamationmark",
                    title: "Plus proposé",
                    message: "Ce cours ou cet événement n'est plus proposé par le club."
                )
            }
        }
        .background(Brand.background.ignoresSafeArea())
        // Titre de la barre : « Cours » ou « Événement », jamais « Activité ».
        .navigationTitle(activity?.type.categoryLabel ?? "Cours")
        .navigationBarTitleDisplayMode(.inline)
        // Personnes au nom de qui le membre peut inscrire, lues pour le club
        // de la session (celle du parent, même s'il agit pour un enfant).
        // Lecture tolérante : liste vide en cas d'échec.
        .task {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            managedProfiles = await ActivityService.managedProfiles(clubId: clubId)
        }
        // « Inscrire qui ? » : un bouton par personne éligible, « Moi-même »
        // pour le membre.
        .confirmationDialog("Inscrire qui ?", isPresented: $isChoosingPerson, titleVisibility: .visible) {
            ForEach(eligiblePeople) { person in
                Button(person.estMoi ? "Moi-même" : person.displayName) {
                    enroll(person)
                }
            }
            Button("Annuler", role: .cancel) {}
        }
        // Confirmation avant de libérer sa place.
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
        // Résultat d'une inscription réussie : inscrit, ou liste d'attente.
        .alert(resultMessage?.title ?? "", isPresented: resultBinding) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage?.message ?? "")
        }
        // Refus ou échec, d'une inscription comme d'une désinscription.
        .alert("Inscription impossible", isPresented: errorBinding) {
            Button("J'ai compris") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Contenu

    /// Les cartes du détail dans un défilement, et la barre d'inscription
    /// fixée en bas.
    /// - Parameter activity: l'activité affichée.
    /// - Returns: le contenu complet de l'écran.
    private func content(_ activity: Activity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(activity)

                // Description libre du club, si elle est renseignée.
                if let description = activity.description, !description.isEmpty {
                    SurfaceCard {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Séances à venir, conditions, puis entraîneur.
                sessionsCard(activity)
                rulesCard(activity)
                coachCard(activity)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        // Barre d'inscription posée sous le contenu, au-dessus de l'indicateur
        // d'accueil : le défilement s'arrête au-dessus d'elle.
        .safeAreaInset(edge: .bottom) { actionBar(activity) }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
    }

    /// Nom de l'activité, pastilles (type, sport, places, « Inscrit ») et
    /// horaire habituel.
    /// - Parameter activity: l'activité affichée.
    /// - Returns: l'en-tête de l'écran.
    private func header(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activity.nom)
                .font(.editorial(.title2))
                .foregroundStyle(Brand.navy800)

            HStack(spacing: 6) {
                // Badge de type : « Cours » ou « Événement », jamais « Activité ».
                BrandChip(title: activity.type.categoryLabel, tint: Brand.navy700)
                BrandChip(title: activity.sport.displayName, systemImage: activity.sport.symbolName, tint: activity.sport.accent)
                // Places : grisée quand c'est complet.
                BrandChip(title: store.placesLabel(for: activity), tint: activity.isFull ? Brand.textSecondary : activity.sport.accent)
                // Inscrit ou en liste d'attente.
                if store.isEnrolled(activity.id) {
                    BrandChip(title: "Inscrit", systemImage: "checkmark", tint: Brand.success)
                }
            }

            // Horaire habituel suivi du terrain ou du lieu, seulement si un
            // horaire est renseigné.
            if let schedule = activity.usualSchedule {
                Text([schedule, courtName(activity.courtId) ?? activity.lieu].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    // MARK: - Séances

    /// Carte des séances prévues à partir d'aujourd'hui (toutes, sans limite
    /// de nombre), séparées par un filet.
    /// - Parameter activity: l'activité affichée.
    /// - Returns: la carte, avec une phrase d'attente s'il n'y en a aucune.
    private func sessionsCard(_ activity: Activity) -> some View {
        let sessions = store.upcoming[activity.id] ?? []

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Séances à venir")
                    .metaLabelStyle()

                // Aucune séance prévue : phrase d'attente.
                if sessions.isEmpty {
                    Text("Aucune séance programmée pour l'instant.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                } else {
                    ForEach(sessions) { session in
                        sessionRow(session, activity: activity)
                        // Filet entre deux séances, pas après la dernière.
                        if session.id != sessions.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    /// Une séance : date longue et horaire, puis terrain et remplaçant
    /// éventuels.
    /// - Parameters:
    ///   - session: la séance (`activite_seances`).
    ///   - activity: son activité, pour reconnaître un remplaçant.
    /// - Returns: la ligne de la séance.
    private func sessionRow(_ session: ActivitySession, activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(session.date.longFrenchDate) · \(session.slot.label)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.textPrimary)

            // Seconde ligne seulement si le terrain ou un remplaçant est connu.
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
    /// - Parameters:
    ///   - session: la séance.
    ///   - activity: son activité.
    /// - Returns: le nom du remplaçant (`activite_seances.entraineur_profile_id`),
    ///   ou `nil` s'il n'y en a pas ou si son nom n'a pas été chargé.
    private func substituteName(_ session: ActivitySession, activity: Activity) -> String? {
        guard let id = session.entraineurProfileId, id != activity.entraineurProfileId else { return nil }
        return store.name(of: id)
    }

    // MARK: - Règles et tarif

    /// Carte « Conditions » : âge, niveau, places, période, fenêtre
    /// d'inscription et tarif, chacun seulement s'il est renseigné (les places
    /// le sont toujours).
    /// - Parameter activity: l'activité affichée.
    /// - Returns: la carte des conditions.
    private func rulesCard(_ activity: Activity) -> some View {
        // Paires (intitulé, valeur) ; les lignes sans valeur sont écartées. Le
        // libellé de niveau perd son préfixe « Niveau », redondant avec
        // l'intitulé de la ligne.
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

                // Intitulé à gauche, valeur à droite.
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

                // Rappel : l'app n'encaisse rien pour les activités, le suivi
                // du règlement est manuel, au club.
                if activity.priceLabel != nil {
                    Text("Tarif indicatif, réglé au club.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    /// Période de l'activité (`date_debut`, `date_fin`).
    /// - Parameter activity: l'activité.
    /// - Returns: « Du (date) au (date) », « À partir du (date) » (dates
    ///   abrégées, `shortFrenchDate`), ou `nil` sans date de début (une date de
    ///   fin seule n'est pas affichée).
    private func period(_ activity: Activity) -> String? {
        switch (activity.dateDebut, activity.dateFin) {
        case let (start?, end?): "Du \(start.shortFrenchDate) au \(end.shortFrenchDate)"
        case let (start?, nil): "À partir du \(start.shortFrenchDate)"
        default: nil
        }
    }

    /// Fenêtre d'inscription (`inscriptions_ouvertes_du`,
    /// `inscriptions_ouvertes_au`), affichée au jour près ; c'est la base qui
    /// l'applique, à l'instant près.
    /// - Parameter activity: l'activité.
    /// - Returns: « Du ... au ... », « À partir du ... », « Jusqu'au ... », ou
    ///   `nil` si les inscriptions ne sont pas bornées.
    private func enrollmentWindow(_ activity: Activity) -> String? {
        switch (activity.inscriptionsOuvertesDu, activity.inscriptionsOuvertesAu) {
        case let (start?, end?): "Du \(start.shortFrenchDate) au \(end.shortFrenchDate)"
        case let (start?, nil): "À partir du \(start.shortFrenchDate)"
        case let (nil, end?): "Jusqu'au \(end.shortFrenchDate)"
        default: nil
        }
    }

    // MARK: - Entraîneur

    /// Carte « Encadré par » : photo ou initiale, nom, et bouton « Écrire »
    /// quand l'entraîneur a un compte. Absente si aucun encadrant n'est connu.
    /// - Parameter activity: l'activité affichée.
    /// - Returns: la carte, ou rien.
    @ViewBuilder
    private func coachCard(_ activity: Activity) -> some View {
        if let name = store.coachName(for: activity) {
            SurfaceCard {
                HStack(spacing: 12) {
                    // Photo de l'entraîneur s'il a un compte ; sinon l'initiale
                    // du nom libre.
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
                        // Ouvre (ou crée) la conversation privée avec
                        // l'entraîneur, dans la feuille de messagerie.
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

    /// Barre du bas : désinscription si le profil est inscrit ou en attente,
    /// sinon inscription (ou entrée en liste d'attente si c'est complet).
    /// - Parameter activity: l'activité affichée.
    /// - Returns: la barre, sur le matériau de barre système.
    @ViewBuilder
    private func actionBar(_ activity: Activity) -> some View {
        VStack(spacing: 6) {
            // Déjà inscrit ou en liste d'attente : rappel de l'état (avec le
            // rang d'attente s'il est connu) et bouton rouge pour libérer sa
            // place, après confirmation.
            if let mine = store.myEnrollment(in: activity.id) {
                Text(mine.statut == .listeAttente
                     ? "Vous êtes en liste d'attente\(mine.rangListeAttente.map { ", rang \($0)" } ?? "")."
                     : "Vous êtes inscrit à \(activity.type.demonstrative).")
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
                // Pas encore inscrit : « S'inscrire », ou « Rejoindre la liste
                // d'attente » quand l'activité est au statut complet. La base
                // décide de toute façon (une liste d'attente pleine est refusée).
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

    /// Appui sur « S'inscrire » : choisit pour qui, sans poser la question
    /// quand la réponse est évidente.
    private func startEnrollment() {
        // Compte d'un enfant sélectionné en haut : c'est lui qu'on inscrit.
        if auth.isActingForChild, let child = eligiblePeople.first(where: { $0.profileId == auth.activeProfile?.id }) {
            enroll(child)
            return
        }
        // « Pour qui ? » seulement quand il y a vraiment un choix.
        // Sinon (personne éligible que soi, ou liste pas encore chargée), on
        // inscrit le membre lui-même : voir l'avertissement en tête de fichier.
        if eligiblePeople.count > 1 {
            isChoosingPerson = true
        } else {
            enroll(nil)
        }
    }

    /// Inscrit une personne par la fonction SQL `inscrire_activite`, puis
    /// affiche le résultat et recharge le magasin.
    /// - Parameter person: la personne choisie ; `nil` ou le membre lui-même
    ///   (`estMoi`) pour s'inscrire soi-même, un enfant sinon.
    private func enroll(_ person: ManagedProfile?) {
        isWorking = true
        // `p_pour_profile_id` à null signifie « pour moi-même » côté base.
        let forId = (person?.estMoi ?? true) ? nil : person?.profileId
        // Prénom de l'enfant pour le message de résultat ; `nil` pour soi.
        let who = forId == nil ? nil : person?.prenom ?? person?.displayName

        Task {
            do {
                let result = try await ActivityService.enroll(activityId: activityId, forProfileId: forId)
                Haptics.success()
                resultMessage = Self.resultText(result, who: who, type: activity?.type ?? .collectif)
                // Relecture : pastilles, places et barre du bas suivent la base.
                await store.reload()
            } catch {
                Haptics.failure()
                errorMessage = enrollmentError(error)
            }
            isWorking = false
        }
    }

    /// Le refus de la base, au bon mot ; sinon la formule du web.
    ///
    /// Le refus (P0001) est repris tel quel, avec « cette activité » remplacé
    /// par « ce cours » ou « cet événement » (`worded(for:)`). Toute autre
    /// erreur (réseau, fonction absente) donne le message générique.
    /// - Parameter error: l'erreur levée par ActivityService.
    /// - Returns: le texte de l'alerte d'échec.
    private func enrollmentError(_ error: Error) -> String {
        let mapped = ActivityServiceError.from(error).worded(for: activity?.type ?? .collectif)
        if case .refused(let message) = mapped { return message }
        return "Impossible de t'inscrire pour l'instant."
    }

    /// Titre et texte de l'alerte de succès.
    /// - Parameters:
    ///   - result: réponse de `inscrire_activite` (statut et rang d'attente).
    ///   - who: prénom de l'enfant inscrit, ou `nil` pour le membre lui-même.
    ///   - type: type de l'activité, pour « ce cours » ou « cet événement ».
    /// - Returns: « Liste d'attente » avec le rang, ou « Inscription
    ///   confirmée ».
    private static func resultText(_ result: EnrollmentResult, who: String?, type: ActivityType) -> (title: String, message: String) {
        let subject = who ?? "Vous"
        switch result.statut {
        case .listeAttente:
            // La promotion automatique est faite par desinscrire_activite
            // quand une place se libère.
            let rank = result.rang.map { ", au rang \($0)" } ?? ""
            return ("Liste d'attente", "\(subject == "Vous" ? "Vous êtes" : "\(subject) est") en liste d'attente\(rank). Une place libérée vous sera attribuée automatiquement.")
        default:
            return ("Inscription confirmée", "\(subject == "Vous" ? "Vous êtes inscrit" : "\(subject) est inscrit") à \(type.demonstrative).")
        }
    }

    /// Libère la place du profil par la fonction SQL `desinscrire_activite`
    /// (inscription passée à `annule`, premier de la liste d'attente promu),
    /// puis recharge le magasin. Appelé après la confirmation.
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
                errorMessage = ActivityServiceError.from(error).worded(for: activity?.type ?? .collectif).localizedDescription
            }
            isWorking = false
        }
    }

    // MARK: - Outils

    /// Nom d'un terrain du catalogue du club.
    /// - Parameter id: identifiant du terrain, ou `nil`.
    /// - Returns: son nom, ou `nil` s'il est absent ou inconnu.
    private func courtName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return catalog.courts.first { $0.id == id }?.nom
    }

    /// Ouvre l'alerte de succès tant qu'un résultat est posé ; la fermer
    /// efface le résultat.
    private var resultBinding: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    /// Même mécanisme pour l'alerte d'échec.
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
