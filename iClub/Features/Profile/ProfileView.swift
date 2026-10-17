//
//  ProfileView.swift
//  iClub
//
//  Identité, photo de profil, informations personnelles et déconnexion.
//  Classements et carte d'adhésion détaillée arrivent à l'étape suivante.
//

import PhotosUI
import SwiftUI

struct ProfileView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var isSigningOut = false
    @State private var showSignOutConfirmation = false

    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?

    /// Photo choisie dans la bibliothèque, en attente d'envoi.
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var photoError: String?

    private var profile: SessionProfile? { auth.sessionProfile }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                identityCard

                if let profile {
                    PersonalInfoSection(profile: profile) {
                        await auth.refreshSessionProfile()
                    }
                    .padding(.horizontal, 20)

                    RankingsSection(profile: profile) {
                        await auth.refreshSessionProfile()
                    }
                    .padding(.horizontal, 20)

                    SuggestionsSection()
                        .padding(.horizontal, 20)
                }

                PhasePlaceholder(
                    systemImage: "pencil.and.list.clipboard",
                    title: "La suite du profil",
                    message: "Carte d'adhésion détaillée."
                )

                signOutButton
                    .padding(.horizontal, 20)

                deleteAccountButton
                    .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
            .padding(.top, 12)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Profil")
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
        .alert("Suppression impossible", isPresented: deleteErrorBinding) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
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

    // MARK: - Identité

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

                        Text(profile.email)
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)

                        Text(profile.clubName)
                            .metaLabelStyle()
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
        } else {
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

    /// Avatar tapable, avec pastille d'appareil photo en coin. On s'appuie sur
    /// `PhotosPicker`, qui présente la bibliothèque hors du processus de l'app :
    /// aucune autorisation à demander, et l'app ne voit que la photo choisie.
    private func editablePhoto(_ profile: SessionProfile) -> some View {
        PhotosPicker(
            selection: $pickedPhoto,
            matching: .images,
            photoLibrary: .shared()
        ) {
            AvatarView(url: profile.avatarUrl, initials: profile.initials, size: 60)
                .overlay {
                    if isUploadingPhoto {
                        ZStack {
                            Circle().fill(.black.opacity(0.35))
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                }
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
        .accessibilityLabel("Modifier ma photo de profil")
    }

    private var photoErrorBinding: Binding<Bool> {
        Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )
    }

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

    private var deleteErrorBinding: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    }

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
struct AvatarView: View {
    let url: URL?
    let initials: String
    var size: CGFloat = 40

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

    private var initialsCircle: some View {
        ZStack {
            Brand.navy700.opacity(0.12)
            Text(initials)
                .font(.system(size: size * 0.38, design: .rounded).weight(.semibold))
                .foregroundStyle(Brand.navy700)
        }
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AuthController())
        .environment(AppRouter())
}
