//
//  CreateCourseView.swift
//  iClub
//
//  Rôle
//    Créer un cours. Les créneaux alloués par le club viennent en premier : un
//    cours posé dedans part directement en ligne. Le formulaire reste libre
//    au-delà ; c'est `creer_activite` qui décide du statut et des dates sautées.
//    Le fichier contient aussi l'écran de confirmation (CourseCreatedView).
//
//  Place dans l'application
//    Poussé depuis « Mes cours » (bouton « Créer un cours » de CoachSpaceView,
//    route `CreateCourseRoute`). Après l'enregistrement, la pile de l'onglet
//    est remplacée par l'écran de confirmation (route `CourseCreatedRoute`).
//
//  Règles métier (appliquées par la fonction SQL `creer_activite`, en une
//  transaction, migration 20261023120000_vacances_scolaires)
//    - réservée à un entraîneur du club ou à un administrateur ;
//    - le terrain doit être un terrain actif du club, du sport choisi ;
//    - statut `ouverte` si le cours tient dans un créneau alloué
//      (`creneaux_entraineur` : même sport, même jour, terrain compatible,
//      horaire et période inclus) ou si le créateur est administrateur ; sinon
//      `proposee`, à valider par le club ;
//    - une séance par semaine, le jour choisi, entre les deux dates ; une date
//      où le terrain est déjà pris (réservation confirmée ou blocage) est
//      sautée et rendue dans `dates_en_conflit` ;
//    - pour un cours `ouverte`, chaque séance bloque le terrain
//      (`slot_overrides`, état « cours ») ; un cours `proposee` ne bloque rien.
//    La fonction accepte aussi la suspension pendant les vacances scolaires
//    (`p_suspendre_vacances`), que l'app n'envoie pas : elle prend sa valeur
//    par défaut (pas de suspension).
//
//  Contrôles faits dans l'app
//    Nom non vide, terrain choisi, fin après le début, date de fin au plus tôt
//    le jour du début (`CourseDraft.isValid`) : le bouton reste grisé sinon.
//

import SwiftUI

/// Formulaire de création d'un cours par l'entraîneur.
struct CreateCourseView: View {
    /// Magasin de l'espace entraîneur (créneaux alloués, rechargement).
    let store: CoachStore

    /// Session : club du cours.
    @Environment(AuthController.self) private var auth
    /// Catalogue du club : sports pratiqués et terrains.
    @Environment(ClubCatalog.self) private var catalog
    /// Routeur, pour remplacer la pile par la confirmation.
    @Environment(AppRouter.self) private var router

    /// Saisie du formulaire (CoachService.swift).
    @State private var draft = CourseDraft()
    /// Interrupteur « Fixer un niveau ».
    @State private var hasLevel = false
    /// Interrupteur « Fixer une tranche d'âge ».
    @State private var hasAge = false
    /// Enregistrement en cours.
    @State private var isSaving = false
    /// Refus ou échec de la création, affiché en bas du formulaire.
    @State private var errorMessage: String?

    /// Jours dans l'ordre de `jour_semaine` : 1 = lundi … 7 = dimanche.
    private static let weekdays = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]
    /// Types de cours proposés à l'entraîneur ; les événements, tournois et
    /// animations restent créés par le club.
    private static let types: [ActivityType] = [.collectif, .stage, .individuel, .duo]

    /// Sports qui ont au moins un terrain au club.
    private var sports: [Sport] { catalog.availableSports }
    /// Un cours n'est pas une réservation : tous les terrains actifs.
    ///
    /// Y compris ceux fermés au groupe de l'utilisateur (`allCourts`, et non
    /// `courts(for:)`).
    private var courts: [Court] { catalog.allCourts(for: draft.sport) }

    /// Le formulaire, et le bouton « Créer le cours » fixé en bas.
    var body: some View {
        Form {
            // Créneaux alloués par le club, s'il y en a : un tap préremplit.
            if !store.slots.isEmpty {
                slotsSection
            }

            // Type, nom, sport et terrain.
            Section("Cours") {
                Picker("Type", selection: $draft.type) {
                    ForEach(Self.types, id: \.self) { Text($0.singularLabel).tag($0) }
                }
                TextField("Nom du cours", text: $draft.nom)
                Picker("Sport", selection: $draft.sport) {
                    ForEach(sports) { Text($0.displayName).tag($0) }
                }
                Picker("Terrain", selection: $draft.courtId) {
                    Text("Choisir").tag(UUID?.none)
                    ForEach(courts) { Text($0.nom).tag(UUID?.some($0.id)) }
                }
                // Un stage créé ici se répète aussi chaque semaine.
                if draft.type == .stage {
                    Text("Un stage se répète ici un jour par semaine. Pour plusieurs jours d'affilée, créez un stage par jour ou demandez au club.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            // Jour de la semaine, heures, et période (la fin ne peut précéder
            // le début).
            Section("Horaire") {
                Picker("Jour", selection: $draft.jourSemaine) {
                    ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                }
                DatePicker("Début", selection: timeBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Fin", selection: timeBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Du", selection: $draft.dateDebut, displayedComponents: .date)
                DatePicker("Au", selection: $draft.dateFin, in: draft.dateDebut..., displayedComponents: .date)
            }

            // Places, niveau et âge.
            Section("Participants") {
                // Leçon : places fixées par le type (1 ou 2) ; sinon de 1 à 40.
                switch draft.type {
                case .individuel:
                    LabeledContent("Places", value: "1")
                case .duo:
                    LabeledContent("Places", value: "2")
                default:
                    Stepper("Places : \(draft.placesMax)", value: $draft.placesMax, in: 1...40)
                }

                // Niveau seulement pour un sport qui a une échelle (tennis,
                // padel ; pas le pickleball).
                if Ranking.hasScale(draft.sport) {
                    Toggle("Fixer un niveau", isOn: $hasLevel.animation())
                    if hasLevel {
                        levelPicker("Niveau minimum", selection: $draft.niveauMin)
                        levelPicker("Niveau maximum", selection: $draft.niveauMax)
                    }
                }

                // Tranche d'âge : de 4 à 18 ans proposés par défaut, réglables
                // de 3 à 99.
                Toggle("Fixer une tranche d'âge", isOn: $hasAge.animation())
                if hasAge {
                    Stepper("Âge minimum : \(draft.ageMin ?? 4) ans", value: ageBinding(\.ageMin, default: 4), in: 3...99)
                    Stepper("Âge maximum : \(draft.ageMax ?? 18) ans", value: ageBinding(\.ageMax, default: 18), in: 3...99)
                }
            }

            // Textes vus par les membres.
            Section {
                TextField("Description (facultatif)", text: $draft.description, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Tarif, ex. « 180 € la saison »", text: $draft.tarifLibelle)
            } header: {
                Text("Pour les membres")
            } footer: {
                Text("Le tarif est indicatif : il s'affiche, il n'est pas encaissé par l'app.")
            }

            // Refus de la base (P0001 en clair) ou échec réseau.
            if let errorMessage {
                Section { InlineMessage(kind: .error, message: errorMessage) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Créer un cours")
        .navigationBarTitleDisplayMode(.inline)
        // Bouton fixé en bas, grisé tant que la saisie n'est pas valide.
        .safeAreaInset(edge: .bottom) {
            PrimaryActionButton(title: "Créer le cours", systemImage: "checkmark", isLoading: isSaving) {
                save()
            }
            .disabled(!draft.isValid || isSaving)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .hidesMessageBubble()
        // Sport par défaut (tennis) absent du club : premier sport pratiqué.
        .onAppear {
            if let first = sports.first, !sports.contains(draft.sport) { draft.sport = first }
        }
        .onChange(of: draft.sport) { _, _ in
            // Le terrain dépend du sport ; un niveau aussi.
            if let courtId = draft.courtId, !courts.contains(where: { $0.id == courtId }) { draft.courtId = nil }
            draft.niveauMin = nil
            draft.niveauMax = nil
        }
        // Niveau désactivé : on n'envoie aucune borne.
        .onChange(of: hasLevel) { _, on in
            if !on { draft.niveauMin = nil; draft.niveauMax = nil }
        }
        // Âge activé : bornes par défaut 4 et 18 ans ; désactivé : aucune.
        .onChange(of: hasAge) { _, on in
            if on {
                draft.ageMin = draft.ageMin ?? 4
                draft.ageMax = draft.ageMax ?? 18
            } else {
                draft.ageMin = nil
                draft.ageMax = nil
            }
        }
    }

    // MARK: - Créneaux du club

    /// Section « Vos créneaux » : un bouton par créneau alloué, qui recopie
    /// dans le formulaire son sport, son terrain (ou, s'il vaut pour tout
    /// terrain, le premier terrain du sport), son jour, ses heures et sa
    /// période (début ramené à aujourd'hui s'il est passé).
    private var slotsSection: some View {
        Section {
            ForEach(store.slots) { slot in
                Button {
                    draft.apply(slot, fallbackCourt: catalog.allCourts(for: slot.sport).first?.id)
                    Haptics.selection()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        // Jour, heure de début et heure de fin du créneau ; le
                        // numéro du jour est borné à 1...7 par prudence.
                        Text("\(Self.weekdays[max(0, min(6, slot.jourSemaine - 1))]) · \(TimeSlot.clock(slot.startMinutes)) – \(TimeSlot.clock(slot.endMinutes))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text(slotDetails(slot))
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        } header: {
            Text("Vos créneaux")
        } footer: {
            Text("Un cours posé dans l'un de vos créneaux est en ligne tout de suite. En dehors, le club doit le valider.")
        }
    }

    /// Détail d'un créneau : sport, terrain (« Tout terrain » s'il n'en fixe
    /// pas) et période.
    /// - Parameter slot: le créneau alloué.
    /// - Returns: la ligne de détail.
    private func slotDetails(_ slot: CoachSlot) -> String {
        let court = slot.courtId.flatMap { id in catalog.courts.first { $0.id == id }?.nom } ?? "Tout terrain"
        return "\(slot.sport.displayName) · \(court) · du \(slot.dateDebut.shortFrenchDate) au \(slot.dateFin.shortFrenchDate)"
    }

    // MARK: - Champs

    /// Sélecteur d'un niveau dans l'échelle du sport, avec « Aucun ».
    /// - Parameters:
    ///   - title: intitulé (« Niveau minimum », « Niveau maximum »).
    ///   - selection: valeur liée, telle qu'écrite en base (point décimal pour
    ///     le padel), ou `nil`.
    /// - Returns: le sélecteur.
    private func levelPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Aucun").tag(String?.none)
            ForEach(Ranking.scale(for: draft.sport), id: \.self) { value in
                Text(Ranking.display(value, sport: draft.sport)).tag(String?.some(value))
            }
        }
    }

    /// Relie un horaire en minutes depuis minuit à un sélecteur d'heure.
    ///
    /// L'heure est posée sur le jour courant pour l'affichage ; seules l'heure
    /// et la minute choisies sont gardées.
    /// - Parameter keyPath: champ du brouillon (`startMinutes` ou `endMinutes`).
    /// - Returns: la liaison de type `Date`.
    private func timeBinding(_ keyPath: WritableKeyPath<CourseDraft, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: draft[keyPath: keyPath], to: Calendar.current.startOfDay(for: .now)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    /// Relie une borne d'âge facultative à un compteur.
    /// - Parameters:
    ///   - keyPath: champ du brouillon (`ageMin` ou `ageMax`).
    ///   - value: valeur montrée tant que la borne est vide.
    /// - Returns: la liaison entière.
    private func ageBinding(_ keyPath: WritableKeyPath<CourseDraft, Int?>, default value: Int) -> Binding<Int> {
        Binding(get: { draft[keyPath: keyPath] ?? value }, set: { draft[keyPath: keyPath] = $0 })
    }

    // MARK: - Enregistrement

    /// Envoie le brouillon à `creer_activite`, recharge le magasin, puis
    /// remplace la pile par l'écran de confirmation.
    private func save() {
        guard let clubId = auth.sessionProfile?.clubId else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let result = try await CoachService.createCourse(draft, clubId: clubId)
                Haptics.success()
                await store.reload()
                // L'écran de confirmation remplace le formulaire : le geste
                // arrière ne doit pas ramener sur un cours déjà créé.
                var path = NavigationPath()
                path.append(CourseCreatedRoute(result: result, nom: draft.nom))
                router.activitiesPath = path
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
            isSaving = false
        }
    }
}

// MARK: - Confirmation

/// Écran qui suit la création : cours en ligne, ou envoyé au club pour
/// validation, avec le nombre de séances créées et les dates sautées.
struct CourseCreatedView: View {
    /// Réponse de `creer_activite`.
    let result: CourseCreationResult
    /// Nom du cours saisi.
    let nom: String

    /// Routeur, pour revenir à la racine de l'onglet.
    @Environment(AppRouter.self) private var router

    /// Vrai si le cours est en ligne (statut `ouverte`), faux s'il attend le
    /// club (`proposee`).
    private var isOnline: Bool { result.statut == .ouverte }

    /// Icône, titre et explication selon le statut, récapitulatif des
    /// séances, et bouton « Voir mes cours ».
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Coche verte (en ligne) ou sablier orange (en attente).
                Image(systemName: isOnline ? "checkmark.circle.fill" : "hourglass.circle.fill")
                    .font(.system(size: 62, weight: .light))
                    .foregroundStyle(isOnline ? Brand.success : Brand.warning)
                    .symbolEffect(.bounce, options: .nonRepeating)

                Text(isOnline ? "Votre cours est en ligne" : "Cours envoyé au club")
                    .font(.editorial(.title2))
                    .foregroundStyle(Brand.navy800)
                    .multilineTextAlignment(.center)

                Text(isOnline
                     ? "« \(nom) » est ouvert aux inscriptions, et ses terrains sont bloqués."
                     : "« \(nom) » sort de vos créneaux : le club doit le valider avant que les membres puissent s'inscrire. Aucun terrain n'est bloqué d'ici là.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Séances créées", value: "\(result.seancesCreees)")
                            .font(.subheadline)

                        // Dates où le terrain était déjà pris : aucune séance
                        // n'y a été posée.
                        if !result.datesEnConflit.isEmpty {
                            Divider().opacity(0.4)
                            Text("Dates sautées, le terrain était déjà pris :")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.textPrimary)
                            ForEach(result.datesEnConflit, id: \.self) { date in
                                Text("• \(date.longFrenchDate)")
                                    .font(.footnote)
                                    .foregroundStyle(Brand.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        // Pas de retour arrière : le formulaire n'est plus dans la pile.
        .navigationBarBackButtonHidden(true)
        // Retour à la racine de l'onglet (segment « Mes cours » conservé).
        .safeAreaInset(edge: .bottom) {
            PrimaryActionButton(title: "Voir mes cours", systemImage: "list.bullet") {
                router.activitiesPath = NavigationPath()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .hidesMessageBubble()
    }
}
