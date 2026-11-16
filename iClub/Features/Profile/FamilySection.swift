//
//  FamilySection.swift
//  iClub
//
//  Rôle
//    « Ma famille » : les enfants dont le membre est responsable. Un enfant n'a
//    ni e-mail ni connexion ; c'est le parent qui réserve et l'inscrit pour lui.
//    Qui est responsable de qui est tenu par la base (table `liens_famille`).
//
//  Place dans l'application
//    Carte de l'onglet Profil (ProfileView). Elle ouvre la feuille d'ajout
//    d'un enfant (AddChildSheet) et la fiche d'un enfant (ChildSheet), dont le
//    contenu (ChildProfileContent) sert aussi à l'onglet Profil quand le parent
//    agit pour l'enfant.
//
//  Données et écritures (MemberDocumentsService, migration
//  20261018160000_comptes_famille)
//    - lecture : fonction SQL `mes_profils_geres` (ProfileExtrasStore) ;
//    - ajout : fonction `creer_compte_enfant`, qui crée un profil sans adresse
//      ni connexion (`compte_gere`), sa fiche de membre du club
//      (`club_members`, rôle « junior », sans adhésion payée), le lien de
//      famille (relation « parent », droits de réserver, payer et inscrire
//      activés), et note la date du consentement parental ; elle
//      refuse un doublon (même prénom, nom et date de naissance) et un compte
//      lui-même géré ;
//    - retrait : fonction `retirer_lien_famille`, qui efface le lien sans
//      supprimer le profil de l'enfant.
//    Après un ajout ou un retrait, la liste et le sélecteur de compte du haut
//    de l'écran (AuthController.reloadFamily) sont relus.
//
//  Points d'attention
//    Attention : la règle « moins de 18 ans » n'est appliquée que par le
//    sélecteur de date de la feuille d'ajout ; la fonction
//    `creer_compte_enfant` ne vérifie que la présence d'une date passée.
//

import SwiftUI

/// Carte « Ma famille » du profil.
struct FamilySection: View {
    /// Le compte connecté (le parent).
    let profile: SessionProfile
    /// Données complémentaires du profil : enfants et pièces.
    let store: ProfileExtrasStore

    /// Session : relecture de la famille pour le sélecteur de compte.
    @Environment(AuthController.self) private var auth

    /// Feuille d'ajout d'un enfant ouverte.
    @State private var isAdding = false
    /// Enfant dont la fiche est ouverte.
    @State private var selectedChild: ManagedProfile?

    /// Carte repliée avec le bouton d'ajout s'il n'y a aucun enfant, sinon la
    /// liste des enfants.
    var body: some View {
        Group {
            if store.children.isEmpty {
                CollapsedProfileCard(title: "Ma famille", message: "Ajoutez un enfant pour réserver et l'inscrire à sa place.") {
                    addButton
                }
            } else {
                // Un enfant par ligne ; un tap ouvre sa fiche.
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

    /// Petit bouton en verre « Ajouter un enfant ».
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

    /// Ligne d'un enfant : photo ou initiales, nom, âge et classements.
    /// - Parameter child: l'enfant.
    /// - Returns: la ligne, cliquable sur toute sa largeur.
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
    ///
    /// Chaque élément seulement s'il est connu ; « Compte géré par vous » si
    /// aucun ne l'est.
    /// - Parameter child: l'enfant.
    /// - Returns: la ligne de détail.
    private func childDetails(_ child: ManagedProfile) -> String {
        var parts: [String] = []
        if let age = child.age { parts.append("\(age) ans") }
        if let tennis = child.classementTennis { parts.append("tennis \(tennis)") }
        if let padel = child.classementPadel { parts.append("padel \(Ranking.display(Ranking.stored(padel: padel), sport: .padel))") }
        return parts.isEmpty ? "Compte géré par vous" : parts.joined(separator: " · ")
    }
}

// MARK: - Ajouter un enfant

/// Feuille d'ajout d'un enfant : prénom, nom, date de naissance, sexe.
struct AddChildSheet: View {
    /// Club où l'enfant est créé (celui du parent).
    let clubId: UUID
    /// Appelée après la création, avant la fermeture (relectures).
    let onAdded: () async -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Prénom saisi.
    @State private var prenom = ""
    /// Nom saisi.
    @State private var nom = ""
    /// Date de naissance ; dix ans avant aujourd'hui en position de départ du
    /// sélecteur.
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -10, to: .now) ?? .now

    /// Un compte famille est celui d'un mineur : né il y a moins de 18 ans.
    /// La base devrait le refuser elle aussi, mais `creer_compte_enfant` ne le
    /// fait pas aujourd'hui (voir l'en-tête) : ce contrôle est le seul.
    ///
    /// Bornes : du lendemain du jour, il y a 18 ans, jusqu'à aujourd'hui inclus.
    private static var birthRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let earliest = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .year, value: -18, to: today) ?? today) ?? today
        return earliest...today
    }
    /// La date a été touchée au moins une fois.
    @State private var hasChosenBirthDate = false
    /// Sexe choisi, facultatif (`nil` : « Non renseigné »).
    @State private var sexe: Sexe?
    /// Création en cours.
    @State private var isSaving = false
    /// Refus ou échec de la création.
    @State private var errorMessage: String?

    /// « Ajouter » permis : prénom et nom non vides, date choisie et dans les
    /// bornes, aucune création en cours.
    private var canSave: Bool {
        !prenom.trimmingCharacters(in: .whitespaces).isEmpty
            && !nom.trimmingCharacters(in: .whitespaces).isEmpty
            && hasChosenBirthDate
            && Self.birthRange.contains(Calendar.current.startOfDay(for: birthDate))
            && !isSaving
    }

    /// Le formulaire, l'erreur éventuelle, « Annuler » et « Ajouter ».
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Prénom", text: $prenom)
                        .textContentType(.givenName)
                    TextField("Nom", text: $nom)
                        .textContentType(.familyName)
                    DatePicker("Date de naissance", selection: dateBinding, in: Self.birthRange, displayedComponents: .date)
                    // « Fille » et « Garçon », envoyés en F et H comme pour un
                    // adulte.
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

    /// Crée l'enfant par `creer_compte_enfant` (prénom et nom nettoyés de
    /// leurs blancs par le service), puis relit et ferme ; un refus de la base
    /// (doublon, date invalide) s'affiche dans le formulaire.
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
    /// L'enfant.
    let child: ManagedProfile
    /// Le compte connecté (le parent).
    let profile: SessionProfile
    /// Données complémentaires du profil (pièces).
    let store: ProfileExtrasStore

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Le contenu de la fiche, avec « OK » pour fermer ; la feuille se ferme
    /// aussi après le retrait de l'enfant.
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
    /// L'enfant.
    let child: ManagedProfile
    /// Le compte connecté (le parent).
    let profile: SessionProfile
    /// Données complémentaires du profil (pièces).
    let store: ProfileExtrasStore
    /// Appelée après le retrait du lien (fermer la feuille, ou revenir au
    /// compte du parent).
    let onRemoved: () -> Void

    /// Session : relecture de la famille après le retrait.
    @Environment(AuthController.self) private var auth
    /// Confirmation du retrait ouverte.
    @State private var confirmRemove = false
    /// Retrait en cours.
    @State private var isRemoving = false
    /// Refus ou échec du retrait.
    @State private var errorMessage: String?

    /// Identité, classements (lecture seule), pièces de l'enfant, erreur
    /// éventuelle et bouton de retrait.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Photo, nom, âge s'il est connu.
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

            // Classements en lecture seule : les fonctions de mise à jour ne
            // valent que pour son propre classement.
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

            // Pièces de l'enfant, avec dépôt et suppression (DocumentsSection).
            let holder = DocumentHolder(profileId: child.profileId, name: child.prenom ?? child.displayName, age: child.age, isMe: false)
            DocumentListCard(holder: holder, profile: profile, store: store)

            if let errorMessage {
                InlineMessage(kind: .error, message: errorMessage)
            }

            // Retrait du lien, après confirmation.
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

    /// Retire le lien par `retirer_lien_famille` (seul le lien de l'appelant
    /// est effacé), relit les enfants et le sélecteur de compte, puis prévient
    /// l'appelant.
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
