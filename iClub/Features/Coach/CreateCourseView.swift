//
//  CreateCourseView.swift
//  iClub
//
//  Créer un cours. Les créneaux alloués par le club viennent en premier : un
//  cours posé dedans part directement en ligne. Le formulaire reste libre
//  au-delà ; c'est `creer_activite` qui décide du statut et des dates sautées.
//

import SwiftUI

struct CreateCourseView: View {
    let store: CoachStore

    @Environment(AuthController.self) private var auth
    @Environment(ClubCatalog.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var draft = CourseDraft()
    @State private var hasLevel = false
    @State private var hasAge = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let weekdays = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]
    private static let types: [ActivityType] = [.collectif, .stage, .individuel, .duo]

    private var sports: [Sport] { catalog.availableSports }
    private var courts: [Court] { catalog.courts(for: draft.sport) }

    var body: some View {
        Form {
            if !store.slots.isEmpty {
                slotsSection
            }

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
                if draft.type == .stage {
                    Text("Un stage se répète ici un jour par semaine. Pour plusieurs jours d'affilée, créez un stage par jour ou demandez au club.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Section("Horaire") {
                Picker("Jour", selection: $draft.jourSemaine) {
                    ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                }
                DatePicker("Début", selection: timeBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Fin", selection: timeBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Du", selection: $draft.dateDebut, displayedComponents: .date)
                DatePicker("Au", selection: $draft.dateFin, in: draft.dateDebut..., displayedComponents: .date)
            }

            Section("Participants") {
                switch draft.type {
                case .individuel:
                    LabeledContent("Places", value: "1")
                case .duo:
                    LabeledContent("Places", value: "2")
                default:
                    Stepper("Places : \(draft.placesMax)", value: $draft.placesMax, in: 1...40)
                }

                if Ranking.hasScale(draft.sport) {
                    Toggle("Fixer un niveau", isOn: $hasLevel.animation())
                    if hasLevel {
                        levelPicker("Niveau minimum", selection: $draft.niveauMin)
                        levelPicker("Niveau maximum", selection: $draft.niveauMax)
                    }
                }

                Toggle("Fixer une tranche d'âge", isOn: $hasAge.animation())
                if hasAge {
                    Stepper("Âge minimum : \(draft.ageMin ?? 4) ans", value: ageBinding(\.ageMin, default: 4), in: 3...99)
                    Stepper("Âge maximum : \(draft.ageMax ?? 18) ans", value: ageBinding(\.ageMax, default: 18), in: 3...99)
                }
            }

            Section {
                TextField("Description (facultatif)", text: $draft.description, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Tarif, ex. « 180 € la saison »", text: $draft.tarifLibelle)
            } header: {
                Text("Pour les membres")
            } footer: {
                Text("Le tarif est indicatif : il s'affiche, il n'est pas encaissé par l'app.")
            }

            if let errorMessage {
                Section { InlineMessage(kind: .error, message: errorMessage) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Créer un cours")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear {
            if let first = sports.first, !sports.contains(draft.sport) { draft.sport = first }
        }
        .onChange(of: draft.sport) { _, _ in
            // Le terrain dépend du sport ; un niveau aussi.
            if let courtId = draft.courtId, !courts.contains(where: { $0.id == courtId }) { draft.courtId = nil }
            draft.niveauMin = nil
            draft.niveauMax = nil
        }
        .onChange(of: hasLevel) { _, on in
            if !on { draft.niveauMin = nil; draft.niveauMax = nil }
        }
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

    private var slotsSection: some View {
        Section {
            ForEach(store.slots) { slot in
                Button {
                    draft.apply(slot, fallbackCourt: catalog.courts(for: slot.sport).first?.id)
                    Haptics.selection()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
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

    private func slotDetails(_ slot: CoachSlot) -> String {
        let court = slot.courtId.flatMap { id in catalog.courts.first { $0.id == id }?.nom } ?? "Tout terrain"
        return "\(slot.sport.displayName) · \(court) · du \(slot.dateDebut.shortFrenchDate) au \(slot.dateFin.shortFrenchDate)"
    }

    // MARK: - Champs

    private func levelPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Aucun").tag(String?.none)
            ForEach(Ranking.scale(for: draft.sport), id: \.self) { value in
                Text(Ranking.display(value, sport: draft.sport)).tag(String?.some(value))
            }
        }
    }

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

    private func ageBinding(_ keyPath: WritableKeyPath<CourseDraft, Int?>, default value: Int) -> Binding<Int> {
        Binding(get: { draft[keyPath: keyPath] ?? value }, set: { draft[keyPath: keyPath] = $0 })
    }

    // MARK: - Enregistrement

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

struct CourseCreatedView: View {
    let result: CourseCreationResult
    let nom: String

    @Environment(AppRouter.self) private var router

    private var isOnline: Bool { result.statut == .ouverte }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
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
        .navigationBarBackButtonHidden(true)
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
