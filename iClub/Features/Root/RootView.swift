//
//  RootView.swift
//  iClub
//
//  Aiguillage entre lancement, authentification et app connectée.
//
//  Rôle
//    Vue racine de la fenêtre (posée par `iClubApp`). Elle choisit l'écran à
//    montrer selon l'état de la session tenu par `AuthController.phase` :
//    écran de lancement, connexion, complétion du profil, application à
//    onglets, ou compte inexploitable. Elle ne lit aucune donnée elle-même.
//
//  Place dans l'application
//    `iClubApp` → `RootView` → l'un des écrans suivants :
//      - `ConfigurationMissingView` si `AppConfiguration.isConfigured` est faux ;
//      - `LaunchView` pendant la lecture de la session enregistrée
//        (`.bootstrapping`) ;
//      - `SignInView` dans sa propre pile de navigation (`.signedOut`), d'où
//        partent l'inscription et le mot de passe oublié ;
//      - `ProfileCompletionView` si le membre connecté n'a pas encore
//        renseigné téléphone, date de naissance ou sexe ;
//      - `MainTabView`, l'application à cinq onglets (`.signedIn`) ;
//      - `BlockedView` quand la session est ouverte mais que le profil club
//        n'est pas exploitable (`.blocked`).
//
//  Règles métier
//    Un profil incomplet bloque l'accès aux onglets, à chaque lancement tant
//    qu'il n'est pas complété (voir `SessionProfile.isComplete`) : l'âge
//    affiché sous chaque joueur et la mixité des parties ouvertes dépendent de
//    ces informations, que ni Apple ni Google ne fournissent.
//
//  Droits et sécurité
//    Aucun contrôle de droit ici : la vue ne fait que refléter la phase
//    calculée par `AuthController`. Les données elles-mêmes restent protégées
//    par la sécurité au niveau des lignes (RLS) de Supabase.
//
//  Effets de bord
//    `.task` démarre l'écoute des changements d'authentification
//    (`AuthController.start()`), qui ne s'abonne qu'une fois même si la vue
//    réapparaît.
//
//  Fil d'exécution
//    Comme tout le projet (réglage `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`),
//    ces vues vivent sur l'acteur principal.
//

import SwiftUI

// MARK: - Aiguillage

/// Écran racine : choisit entre configuration manquante, lancement, connexion,
/// complétion du profil, application à onglets et compte bloqué, d'après la
/// phase de `AuthController`. Les changements de phase sont animés par un
/// fondu (0,4 s).
struct RootView: View {
    /// Contrôleur de session global, injecté par `iClubApp` : sa `phase` décide
    /// de l'écran affiché.
    @Environment(AuthController.self) private var auth

    /// L'écran correspondant à la phase de session, avec un fondu entre deux
    /// phases.
    var body: some View {
        Group {
            // Identifiants Supabase absents de `AppConfiguration` : écran
            // d'explication plutôt qu'un plantage au premier appel réseau.
            if !AppConfiguration.isConfigured {
                ConfigurationMissingView()
            } else {
                switch auth.phase {
                // Lecture de la session enregistrée sur l'appareil, au lancement.
                case .bootstrapping:
                    LaunchView()
                // Personne n'est connecté : connexion, dans sa propre pile pour
                // pouvoir pousser l'inscription et le mot de passe oublié.
                case .signedOut:
                    NavigationStack {
                        SignInView()
                    }
                    .transition(.opacity)
                case .signedIn:
                    // Pas d'accès à l'app tant que le profil est incomplet :
                    // l'âge affiché et la mixité des parties en dépendent, et
                    // le membre ne ferait jamais le lien.
                    // C'est le compte connecté (`sessionProfile`) qui est
                    // contrôlé, jamais l'enfant éventuellement sélectionné.
                    if let profile = auth.sessionProfile, !profile.isComplete {
                        ProfileCompletionView(profile: profile)
                            .transition(.opacity)
                    } else {
                        // Profil complet : l'application à onglets, qui entre
                        // avec un léger zoom en plus du fondu.
                        MainTabView()
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    }
                // Session ouverte mais profil club inexploitable (aucune
                // appartenance au club, ou échec de chargement) : le message
                // vient de `AuthController`.
                case .blocked(let message):
                    BlockedView(message: message)
                }
            }
        }
        // Toute bascule de phase est animée (fondu de 0,4 s).
        .animation(.smooth(duration: 0.4), value: auth.phase)
        // Démarre l'écoute de Supabase Auth ; l'événement `.initialSession`
        // fait sortir l'app de `.bootstrapping`.
        .task { auth.start() }
    }
}

// MARK: - Lancement

/// Écran de lancement : le logo iClub et une roue d'attente sur le fond en
/// dégradé, le temps que Supabase relise la session enregistrée. Aucune
/// donnée, aucune action.
struct LaunchView: View {
    /// Fond en dégradé, logo et roue d'attente, centrés.
    var body: some View {
        ZStack {
            // Fond en dégradé maillé commun aux écrans d'authentification.
            AuroraBackground()
            // Logo et indicateur d'activité, centrés.
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
///
/// Affichée par `RootView` pour la phase `.blocked`, par exemple quand le
/// compte n'est rattaché à aucun club et que le rattachement automatique
/// (`join_club_as_member`) a échoué, ou quand le profil n'a pas pu être lu.
struct BlockedView: View {
    /// Message déjà rédigé pour le membre, porté par la phase `.blocked`
    /// (par exemple celui de `SessionProfileError.noClubMembership`).
    let message: String

    /// Contrôleur de session : nouvelle tentative et déconnexion.
    @Environment(AuthController.self) private var auth
    /// Vrai pendant la nouvelle tentative, pour la roue du bouton.
    @State private var isRetrying = false

    /// Pictogramme, titre « Compte en attente », message, puis les boutons
    /// « Réessayer » et « Se déconnecter ».
    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 22) {
                // Pictogramme de compte en attente, dans une pastille en verre.
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.primary)
                    .frame(width: 96, height: 96)
                    .glassEffect(.regular, in: .circle)

                // Titre, puis l'explication transmise par `AuthController`.
                Text("Compte en attente")
                    .font(.editorial(.title2))
                    .foregroundStyle(Brand.navy800)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)

                // Les deux sorties possibles : réessayer, ou se déconnecter.
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 12) {
                        // Relance le chargement du profil (`AuthController.retry`).
                        // Attention : `retry()` repasse aussitôt la phase à
                        // `.bootstrapping`, si bien que l'écran de lancement
                        // remplace cette vue pendant la tentative ; la roue du
                        // bouton n'est donc visible qu'un instant.
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

                        // Déconnexion complète (appareil oublié pour les
                        // notifications, rappels effacés), puis retour à
                        // l'écran de connexion.
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
            // Largeur bornée pour rester lisible sur iPad.
            .frame(maxWidth: 440)
        }
    }
}

// MARK: - Configuration absente

/// Affiché tant que les identifiants Supabase ne sont pas renseignés, plutôt
/// que de laisser l'app planter au premier appel réseau.
///
/// Écran destiné au développeur : il n'apparaît jamais dans une version
/// correctement configurée, puisque `AppConfiguration` porte l'URL du projet
/// et la clé publique.
struct ConfigurationMissingView: View {
    /// Carte d'explication centrée sur le fond de l'app.
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()

            // Carte d'explication : pictogramme, titre et marche à suivre.
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

// MARK: - Aperçus Xcode

/// Aperçu de l'écran de lancement dans le canevas d'Xcode.
#Preview("Lancement") {
    LaunchView()
}

/// Aperçu de l'écran de configuration manquante.
#Preview("Configuration") {
    ConfigurationMissingView()
}
