//
//  ProfileView.swift
//  iClub
//
//  Rôle
//    Même contenu que le profil web (/member/profil), dans la direction
//    artistique de l'app : identité et adhésion, informations personnelles,
//    adhésion, classements, famille, pièces, reçus, notifications, autres
//    espaces, déconnexion et suppression du compte.
//
//  Place dans l'application
//    Racine de l'onglet « Profil » (MainTabView). Les cartes sont des vues
//    séparées : PersonalInfoSection, MembershipSection et ReceiptsSection
//    (ProfileCards.swift), RankingsSection, FamilySection, DocumentsSection,
//    GameNotificationsSection, OtherSpacesRow. La suppression du compte passe
//    par DeleteAccountSheet. Ce fichier contient aussi AvatarView, la photo
//    ronde avec repli sur les initiales, utilisée dans toute l'app.
//
//  Données
//    Le profil de session (`AuthController.sessionProfile` : profils,
//    membre du club, adhésion active) et ProfileExtrasStore (enfants, pièces,
//    reçus, sous-domaine du club).
//
//  Compte d'un enfant
//    Quand le parent agit pour un enfant (sélecteur de compte en haut),
//    l'onglet n'affiche que la fiche de l'enfant et le retour à son propre
//    compte : informations, déconnexion et suppression restent celles du
//    parent.
//
//  Effets de bord
//    Photo de profil envoyée ou retirée (AvatarService, stockage Supabase et
//    `profiles.avatar_url`), déconnexion, suppression du compte (fonction SQL
//    `delete_my_account`, par AuthService), remise à zéro de la navigation.
//

import PhotosUI
import SwiftUI

/// Écran de l'onglet « Profil ».
struct ProfileView: View {
    /// Session : profil, compte d'enfant actif, déconnexion.
    @Environment(AuthController.self) private var auth
    /// Routeur, remis à zéro après la suppression du compte.
    @Environment(AppRouter.self) private var router

    /// Déconnexion en cours.
    @State private var isSigningOut = false
    /// Fenêtre de confirmation de la déconnexion ouverte.
    @State private var showSignOutConfirmation = false

    /// Feuille de suppression du compte ouverte.
    @State private var showDeleteConfirmation = false
    /// Suppression du compte en cours.
    @State private var isDeletingAccount = false
    /// Message de l'alerte « Suppression impossible ».
    @State private var deleteError: String?

    /// Photo choisie dans la bibliothèque, en attente d'envoi.
    @State private var pickedPhoto: PhotosPickerItem?
    /// Sélecteur de photos du système ouvert.
    @State private var showsPhotoLibrary = false
    /// Envoi ou retrait de la photo en cours.
    @State private var isUploadingPhoto = false
    /// Message de l'alerte « Photo non enregistrée ».
    @State private var photoError: String?

    /// Enfants, pièces, reçus : ce que l'écran lit en plus du profil de session.
    @State private var extras = ProfileExtrasStore()

    /// Le compte connecté (toujours le parent, même s'il agit pour un enfant).
    private var profile: SessionProfile? { auth.sessionProfile }

    /// La fiche de l'enfant ou le contenu du compte, avec les fenêtres de
    /// confirmation, d'alerte et le sélecteur de photos.
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Compte d'un enfant sélectionné : sa fiche seulement.
                if auth.isActingForChild, let profile, let child = actingChild {
                    childPane(child, parent: profile)
                } else {
                    accountContent
                }
            }
            .padding(.top, 12)
        }
        .background(Brand.background.ignoresSafeArea())
        // Titre : prénom de l'enfant quand on agit pour lui.
        .navigationTitle(auth.isActingForChild ? (actingChild?.prenom ?? "Profil") : "Profil")
        // Données complémentaires, chargées pour le compte connecté.
        .task(id: profile?.id) {
            guard let profile else { return }
            await extras.load(profile: profile)
        }
        // « Tirer pour rafraîchir » : profil de session puis données
        // complémentaires.
        .refreshable {
            await auth.refreshSessionProfile()
            if let profile { await extras.load(profile: profile) }
        }
        // Sélecteur de photos du système, ouvert par le menu de l'avatar.
        .photosPicker(isPresented: $showsPhotoLibrary, selection: $pickedPhoto, matching: .images, photoLibrary: .shared())
        // Confirmation de la déconnexion.
        .confirmationDialog(
            "Se déconnecter de iClub ?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Se déconnecter", role: .destructive) { signOut() }
            Button("Annuler", role: .cancel) {}
        }
        // Deux étapes : la feuille explique ce qui est supprimé et ce que le
        // club conserve, puis une alerte destructive confirme.
        .sheet(isPresented: $showDeleteConfirmation) {
            DeleteAccountSheet(isDeleting: isDeletingAccount) { deleteAccount() }
        }
        // Refus (seul administrateur du club, fonction absente) ou échec.
        .alert("Suppression impossible", isPresented: deleteErrorBinding) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        // Échec de l'envoi ou du retrait de la photo.
        .alert("Photo non enregistrée", isPresented: photoErrorBinding) {
            Button("OK") { photoError = nil }
        } message: {
            Text(photoError ?? "")
        }
        // La sélection est remise à zéro après envoi : choisir deux fois la
        // même photo doit relancer l'envoi.
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            uploadPhoto(item)
        }
    }

    /// L'enfant pour qui l'on agit, s'il y en a un.
    private var actingChild: ManagedProfile? {
        auth.managedChildren.first { $0.profileId == auth.activeProfile?.id }
    }

    /// Onglet Profil en compte enfant : sa fiche, et le retour à son compte.
    /// Le compte lui-même (informations, déconnexion, suppression) reste celui
    /// du parent, accessible en revenant à son compte.
    /// - Parameters:
    ///   - child: l'enfant sélectionné.
    ///   - parent: le compte connecté.
    /// - Returns: le bandeau d'information, la fiche de l'enfant et le bouton
    ///   de retour.
    private func childPane(_ child: ManagedProfile, parent: SessionProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InlineMessage(kind: .info, message: "Vous gérez le compte de \(child.prenom ?? child.displayName). Réservations, parties, cours et événements se font à son nom.")
            // Retirer l'enfant de la famille ramène aussi au compte du parent.
            ChildProfileContent(child: child, profile: parent, store: extras) {
                auth.act(for: nil)
            }
            // Retour au compte du parent : tous les onglets repassent à son nom.
            Button {
                Haptics.selection()
                auth.act(for: nil)
            } label: {
                Label("Revenir à mon compte", systemImage: "arrow.uturn.backward")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 20)
    }

    /// Le compte du membre, carte par carte, dans l'ordre du profil web ; puis
    /// déconnexion et suppression.
    @ViewBuilder
    private var accountContent: some View {
        identityCard

        // Les cartes ont besoin du profil chargé ; les écritures (informations,
        // classements) relisent ensuite le profil de session.
        if let profile {
            PersonalInfoSection(profile: profile) {
                await auth.refreshSessionProfile()
            }
            .padding(.horizontal, 20)

            MembershipSection(profile: profile)
                .padding(.horizontal, 20)

            RankingsSection(profile: profile) {
                await auth.refreshSessionProfile()
            }
            .padding(.horizontal, 20)

            FamilySection(profile: profile, store: extras)
                .padding(.horizontal, 20)

            DocumentsSection(profile: profile, store: extras)
                .padding(.horizontal, 20)

            ReceiptsSection(receipts: extras.receipts, clubSlug: extras.clubSlug)
                .padding(.horizontal, 20)

            GameNotificationsSection(profileId: profile.id)
                .padding(.horizontal, 20)

            OtherSpacesRow(profile: profile, clubSlug: extras.clubSlug)
                .padding(.horizontal, 20)
        }

        signOutButton
            .padding(.horizontal, 20)

        deleteAccountButton
            .padding(.horizontal, 20)

        Spacer(minLength: 24)
    }

    // MARK: - Identité

    /// Carte d'identité : photo modifiable, nom, courriel, club et pastille
    /// d'adhésion ; squelettes tant que le profil n'est pas chargé.
    @ViewBuilder
    private var identityCard: some View {
        if let profile {
            SurfaceCard {
                HStack(spacing: 14) {
                    editablePhoto(profile)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(.editorial(.title3))
                            .foregroundStyle(Brand.textPrimary)

                        // Tronquée au milieu, jamais coupée dans l'adresse.
                        Text(profile.email)
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(profile.clubName)
                            .metaLabelStyle()
                            .padding(.top, 2)

                        MembershipBadge(profile: profile)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
        } else {
            // Profil pas encore chargé : deux lignes de squelette.
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 20)
                    SkeletonBlock(height: 14)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Photo de profil

    /// Avatar tapable : « Changer la photo », et « Retirer la photo » quand il y
    /// en a une. La bibliothèque passe par le sélecteur système, hors du
    /// processus de l'app : aucune autorisation à demander.
    /// - Parameter profile: le compte connecté.
    /// - Returns: le menu, dont l'étiquette est la photo de 60 points avec un
    ///   badge appareil photo, ou un voile et un indicateur pendant l'envoi.
    private func editablePhoto(_ profile: SessionProfile) -> some View {
        Menu {
            Button("Changer la photo", systemImage: "photo.on.rectangle") {
                showsPhotoLibrary = true
            }
            if profile.avatarUrl != nil {
                Button("Retirer la photo", systemImage: "trash", role: .destructive) {
                    removePhoto()
                }
            }
        } label: {
            AvatarView(url: profile.avatarUrl, initials: profile.initials, size: 60)
                // Pendant l'envoi : voile sombre et indicateur d'activité.
                .overlay {
                    if isUploadingPhoto {
                        ZStack {
                            Circle().fill(.black.opacity(0.35))
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                }
                // Au repos : petit badge appareil photo en bas à droite.
                .overlay(alignment: .bottomTrailing) {
                    if !isUploadingPhoto {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Brand.navy700, in: .circle)
                            .overlay {
                                Circle().strokeBorder(Brand.surface, lineWidth: 1.5)
                            }
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingPhoto)
        .accessibilityLabel("Photo de profil")
    }

    /// Retire la photo (AvatarService : fichier du stockage et
    /// `profiles.avatar_url`), puis relit le profil de session pour que les
    /// initiales reprennent sa place partout.
    private func removePhoto() {
        guard let profileId = profile?.id else { return }
        isUploadingPhoto = true
        photoError = nil
        Task {
            do {
                try await AvatarService.removePhoto(profileId: profileId)
                await auth.refreshSessionProfile()
                Haptics.success()
            } catch {
                photoError = error.localizedDescription
                Haptics.warning()
            }
            isUploadingPhoto = false
        }
    }

    /// Ouvre l'alerte de photo tant qu'une erreur est posée ; la fermer
    /// l'efface.
    private var photoErrorBinding: Binding<Bool> {
        Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )
    }

    /// Lit la photo choisie et l'envoie (AvatarService la recadre en carré et
    /// l'écrit dans le stockage), puis relit le profil de session.
    /// - Parameter item: la photo choisie dans le sélecteur du système.
    private func uploadPhoto(_ item: PhotosPickerItem) {
        guard let profileId = profile?.id else { return }
        isUploadingPhoto = true
        photoError = nil

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AvatarError.unreadableImage
                }
                _ = try await AvatarService.updatePhoto(profileId: profileId, imageData: data)
                // Le profil de session porte l'URL versionnée : la relecture
                // suffit à faire apparaître la nouvelle photo partout.
                await auth.refreshSessionProfile()
                Haptics.success()
            } catch {
                photoError = error.localizedDescription
                Haptics.warning()
            }
            pickedPhoto = nil
            isUploadingPhoto = false
        }
    }

    // MARK: - Déconnexion

    /// Bouton en verre teinté de rouge « Se déconnecter », qui ouvre la
    /// confirmation ; indicateur d'activité pendant la déconnexion.
    private var signOutButton: some View {
        Button {
            showSignOutConfirmation = true
        } label: {
            HStack(spacing: 8) {
                if isSigningOut {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("Se déconnecter")
                    .font(.system(.headline, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .tint(Brand.error)
        .foregroundStyle(Brand.error)
        .disabled(isSigningOut)
    }

    // MARK: - Suppression du compte

    /// Plus discret que « Se déconnecter » : un bouton texte, pas un bouton
    /// plein. On ne doit pas pouvoir le confondre avec l'action courante.
    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: 6) {
                if isDeletingAccount {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Supprimer mon compte")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(Brand.error)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isDeletingAccount || isSigningOut)
    }

    /// Ouvre l'alerte de suppression tant qu'une erreur est posée.
    private var deleteErrorBinding: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    }

    /// Supprime le compte, après la double confirmation de DeleteAccountSheet.
    ///
    /// AuthService.deleteMyAccount efface d'abord les fichiers de photo, retire
    /// l'appareil des notifications et les rappels programmés, puis appelle la
    /// fonction SQL `delete_my_account`, qui anonymise le profil, annule les
    /// réservations à venir créées par le membre, le retire des parties à
    /// venir, et supprime son utilisateur d'authentification. Elle refuse si
    /// le membre est le seul administrateur de son club.
    ///
    /// Attention : les fichiers de photo sont effacés avant l'appel ; si la
    /// fonction refuse ensuite, le compte reste mais sa photo est perdue
    /// (`avatar_url` pointe alors vers un fichier absent).
    private func deleteAccount() {
        guard let profileId = profile?.id else { return }
        isDeletingAccount = true
        Task {
            do {
                try await AuthService.deleteMyAccount(profileId: profileId)
                Haptics.destructive()
                showDeleteConfirmation = false
                // Remet l'état global à zéro : le profil en mémoire disparaît,
                // et `RootView` bascule sur l'écran de connexion, ce qui
                // démonte les onglets et leurs magasins (réservations,
                // parties, accueil) avec tout ce qu'ils avaient chargé.
                await auth.signOut()
                router.reset()
            } catch {
                // La feuille se ferme pour laisser lire l'erreur.
                showDeleteConfirmation = false
                deleteError = error.localizedDescription
                Haptics.failure()
            }
            isDeletingAccount = false
        }
    }

    /// Déconnexion après confirmation. AuthController (puis AuthService) oublie
    /// l'appareil pour les notifications, retire les rappels programmés et vide
    /// la messagerie avant de fermer la session ; RootView revient alors à
    /// l'écran de connexion.
    private func signOut() {
        isSigningOut = true
        Haptics.destructive()
        Task {
            await auth.signOut()
            isSigningOut = false
        }
    }
}

/// Photo de profil avec repli sur les initiales.
///
/// Ronde, cerclée d'un filet discret, cachée à VoiceOver (le nom voisin suffit).
/// Les initiales s'affichent sans adresse de photo, pendant son chargement et
/// en cas d'échec.
struct AvatarView: View {
    /// Adresse de la photo, ou `nil`.
    let url: URL?
    /// Initiales de repli.
    let initials: String
    /// Diamètre en points (40 par défaut).
    var size: CGFloat = 40

    /// La photo chargée, ou le disque d'initiales.
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initialsCircle
                    }
                }
            } else {
                initialsCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            Circle().strokeBorder(Brand.hairline, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// Disque bleu marine pâle avec les initiales, à 38 % du diamètre.
    private var initialsCircle: some View {
        ZStack {
            Brand.navy700.opacity(0.12)
            Text(initials)
                .font(.system(size: size * 0.38, design: .rounded).weight(.semibold))
                .foregroundStyle(Brand.navy700)
        }
    }
}

/// Aperçu Xcode, sans session (cartes en squelette).
#Preview {
    NavigationStack { ProfileView() }
        .environment(AuthController())
        .environment(AppRouter())
}
