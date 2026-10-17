//
//  RootView.swift
//  iClub
//
//  Aiguillage entre lancement, authentification et app connectée.
//

import SwiftUI

struct RootView: View {
    @Environment(AuthController.self) private var auth

    var body: some View {
        Group {
            if !AppConfiguration.isConfigured {
                ConfigurationMissingView()
            } else {
                switch auth.phase {
                case .bootstrapping:
                    LaunchView()
                case .signedOut:
                    NavigationStack {
                        SignInView()
                    }
                    .transition(.opacity)
                case .signedIn:
                    // Pas d'accès à l'app tant que le profil est incomplet :
                    // l'âge affiché et la mixité des parties en dépendent, et
                    // le membre ne ferait jamais le lien.
                    if let profile = auth.sessionProfile, !profile.isComplete {
                        ProfileCompletionView(profile: profile)
                            .transition(.opacity)
                    } else {
                        MainTabView()
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    }
                case .blocked(let message):
                    BlockedView(message: message)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: auth.phase)
        .task { auth.start() }
    }
}

// MARK: - Lancement

struct LaunchView: View {
    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 20) {
                BrandMark()
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }
}

// MARK: - Session inexploitable

/// Authentifié mais sans profil club utilisable : on n'enferme pas l'utilisateur,
/// il peut réessayer ou se déconnecter.
struct BlockedView: View {
    let message: String

    @Environment(AuthController.self) private var auth
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 22) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.primary)
                    .frame(width: 96, height: 96)
                    .glassEffect(.regular, in: .circle)

                Text("Compte en attente")
                    .font(.editorial(.title2))
                    .foregroundStyle(Brand.navy800)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)

                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 12) {
                        PrimaryActionButton(
                            title: "Réessayer",
                            systemImage: "arrow.clockwise",
                            isLoading: isRetrying
                        ) {
                            isRetrying = true
                            Task {
                                await auth.retry()
                                isRetrying = false
                            }
                        }

                        SecondaryActionButton(
                            title: "Se déconnecter",
                            systemImage: "rectangle.portrait.and.arrow.right"
                        ) {
                            Task { await auth.signOut() }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 440)
        }
    }
}

// MARK: - Configuration absente

/// Affiché tant que les identifiants Supabase ne sont pas renseignés, plutôt
/// que de laisser l'app planter au premier appel réseau.
struct ConfigurationMissingView: View {
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Brand.warning)

                Text("Configuration Supabase manquante")
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Renseigne `supabaseURL` et `supabaseAnonKey` dans Core/AppConfiguration.swift, puis relance l'app.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .surfaceCard()
            .padding(.horizontal, 28)
        }
    }
}

#Preview("Lancement") {
    LaunchView()
}

#Preview("Configuration") {
    ConfigurationMissingView()
}
