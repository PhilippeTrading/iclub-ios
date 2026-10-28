//
//  FamilySection.swift
//  iClub
//
//  « Ma famille » : les enfants dont le membre est responsable. Un enfant n'a
//  ni e-mail ni connexion ; c'est le parent qui réserve et l'inscrit pour lui.
//  Qui est responsable de qui, et la règle du mineur, sont tenus par la base.
//

import SwiftUI

struct FamilySection: View {
    let profile: SessionProfile
    let store: ProfileExtrasStore

    @Environment(AuthController.self) private var auth

    @State private var isAdding = false
    @State private var selectedChild: ManagedProfile?

    var body: some View {
        Group {
            if store.children.isEmpty {
                CollapsedProfileCard(title: "Ma famille", message: "Ajoutez un enfant pour réserver et l'inscrire à sa place.") {
                    addButton
                }
            } else {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ProfileCardHeader(title: "Ma famille") { addButton }
                        ForEach(store.children) { child in
                            Button { selectedChild = child } label: { childRow(child) }
                                .buttonStyle(.plain)
                            if child.id != store.children.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddChildSheet(clubId: profile.clubId) {
                await store.reloadChildren(profile: profile)
                // Le sélecteur de compte, en haut, doit connaître le nouvel enfant.
                await auth.reloadFamily()
            }
        }
        .sheet(item: $selectedChild) { child in
            ChildSheet(child: child, profile: profile, store: store)
        }
    }

    private var addButton: some View {
        Button {
            isAdding = true
        } label: {
            Label("Ajouter un enfant", systemImage: "plus")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    private func childRow(_ child: ManagedProfile) -> some View {
        HStack(spacing: 12) {
            MemberAvatar(url: child.avatarUrl.flatMap(URL.init(string:)), initials: child.initials, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.displayName)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(childDetails(child))
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
        }
        .contentShape(.rect)
    }

    /// « 11 ans · tennis 30/5 · padel 2,5 ».
    private func childDetails(_ child: ManagedProfile) -> String {
        var parts: [String] = []
        if let age = child.age { parts.append("\(age) ans") }
        if let tennis = child.classementTennis { parts.append("tennis \(tennis)") }
        if let padel = child.classementPadel { parts.append("padel \(Ranking.display(Ranking.stored(padel: padel), sport: .padel))") }
        return parts.isEmpty ? "Compte géré par vous" : parts.joined(separator: " · ")
    }
}

// MARK: - Ajouter un enfant

struct AddChildSheet: View {
    let clubId: UUID
    let onAdded: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prenom = ""
    @State private var nom = ""
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -10, to: .now) ?? .now

    /// Un compte famille est celui d'un mineur : né il y a moins de 18 ans.
    /// La base doit le refuser elle aussi — ce contrôle-ci n'est qu'un confort.
    private static var birthRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let earliest = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .year, value: -18, to: today) ?? today) ?? today
        return earliest...today
    }
    @State private var hasChosenBirthDate = false
    @State private var sexe: Sexe?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && hasChosenBirthDate
            && Self.birthRange.contains(Calendar.current.startOfDay(for: birthDate))
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Prénom", text: $prenom)
                        .textContentType(.givenName)
                    TextField("Nom", text: $nom)
                        .textContentType(.familyName)
                    DatePicker("Date de naissance", selection: dateBinding, in: Self.birthRange, displayedComponents: .date)
                    Picker("Sexe", selection: $sexe) {
                        Text("Non renseigné").tag(Sexe?.none)
                        Text("Fille").tag(Sexe?.some(.femme))
                        Text("Garçon").tag(Sexe?.some(.homme))
                    }
                } footer: {
                    Text("Pour un enfant de moins de 18 ans dont vous êtes responsable. Il n'a ni e-mail ni connexion : c'est vous qui réservez et l'inscrivez pour lui.")
                }

                if let errorMessage {
                    Section { InlineMessage(kind: .error, message: errorMessage) }
                }
            }
            .navigationTitle("Ajouter un enfant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    /// La date par défaut n'est pas une réponse : elle doit être choisie.
    private var dateBinding: Binding<Date> {
        Binding(get: { birthDate }, set: { birthDate = $0; hasChosenBirthDate = true })
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await MemberDocumentsService.createChild(clubId: clubId, prenom: prenom, nom: nom, birthDate: birthDate, sexe: sexe)
                Haptics.success()
                await onAdded()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
            isSaving = false
        }
    }
}

// MARK: - Fiche d'un enfant

/// La fiche, en feuille depuis « Ma famille ».
struct ChildSheet: View {
    let child: ManagedProfile
    let profile: SessionProfile
    let store: ProfileExtrasStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ChildProfileContent(child: child, profile: profile, store: store) { dismiss() }
                    .padding(20)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Fiche de l'enfant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

/// Le contenu de la fiche : identité, classements, pièces, retrait du lien.
/// Partagé par la feuille et par l'onglet Profil quand on agit pour l'enfant.
struct ChildProfileContent: View {
    let child: ManagedProfile
    let profile: SessionProfile
    let store: ProfileExtrasStore
    let onRemoved: () -> Void

    @Environment(AuthController.self) private var auth
    @State private var confirmRemove = false
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MemberAvatar(url: child.avatarUrl.flatMap(URL.init(string:)), initials: child.initials, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.displayName)
                        .font(.editorial(.title3))
                        .foregroundStyle(Brand.navy800)
                    if let age = child.age {
                        Text("\(age) ans").font(.footnote).foregroundStyle(Brand.textSecondary)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    ProfileCardHeader(title: "Classements")
                    LabeledContent("Tennis", value: child.classementTennis ?? "Non classé")
                    LabeledContent("Padel", value: child.classementPadel.map { Ranking.display(Ranking.stored(padel: $0), sport: .padel) } ?? "Non classé")
                    Text("Le classement d'un enfant se met à jour au club.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                .font(.subheadline)
            }

            let holder = DocumentHolder(profileId: child.profileId, name: child.prenom ?? child.displayName, age: child.age, isMe: false)
            DocumentListCard(holder: holder, profile: profile, store: store)

            if let errorMessage {
                InlineMessage(kind: .error, message: errorMessage)
            }

            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Retirer de ma famille", systemImage: "person.crop.circle.badge.minus")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.error)
            .disabled(isRemoving)
        }
        .confirmationDialog("Retirer \(child.prenom ?? child.displayName) de votre famille ?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Retirer le lien", role: .destructive) { remove() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Retirer le lien ne supprime pas le compte de l'enfant.")
        }
    }

    private func remove() {
        isRemoving = true
        Task {
            do {
                try await MemberDocumentsService.removeChild(child.profileId)
                Haptics.destructive()
                await store.reloadChildren(profile: profile)
                await auth.reloadFamily()
                onRemoved()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
            isRemoving = false
        }
    }
}
