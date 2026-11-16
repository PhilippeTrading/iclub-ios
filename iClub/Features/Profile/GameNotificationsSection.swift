//
//  GameNotificationsSection.swift
//  iClub
//
//  Rôle
//    Carte « Notifications » du profil, avec deux réglages :
//    - « Me proposer des parties sur mes créneaux habituels ». Écrit
//      `profiles.notifications_parties`, distinct de l'autorisation système :
//      couper ces propositions ne coupe pas les messages importants, comme
//      l'annulation d'une partie où le membre est inscrit. Le serveur, qui
//      choisit les destinataires des propositions, lit ce réglage ;
//    - « Rappel avant mes réservations » : réglage de l'appareil seulement
//      (UserDefaults, BookingReminders.isEnabled), qui programme ou retire les
//      rappels locaux une heure avant chaque réservation.
//
//  Place dans l'application
//    Carte de l'onglet Profil (ProfileView), pour le compte connecté.
//
//  Autorisation du système
//    Si l'utilisateur a refusé les notifications pour iClub dans les réglages
//    de l'iPhone, les deux interrupteurs sont désactivés et un lien ouvre les
//    Réglages. Si la question n'a jamais été posée, un bouton la pose : c'est
//    un geste explicite du membre, donc le bon moment.
//

import SwiftUI
import UIKit
import UserNotifications

/// Carte des réglages de notification.
struct GameNotificationsSection: View {
    /// Profil dont on lit et écrit `notifications_parties` (le compte connecté).
    let profileId: UUID

    /// Retour au premier plan : l'autorisation a pu changer dans les Réglages.
    @Environment(\.scenePhase) private var scenePhase

    /// Valeur affichée du réglage des propositions de parties (vrai par
    /// défaut, avant lecture).
    @State private var isOn = true
    /// Réglage lu en base.
    @State private var isLoaded = false
    /// Écriture du réglage en cours.
    @State private var isSaving = false
    /// Échec de l'écriture.
    @State private var errorMessage: String?
    /// Autorisation des notifications accordée à l'app par iOS.
    @State private var systemStatus: UNAuthorizationStatus = .notDetermined
    /// Rappels de réservation activés sur cet appareil.
    @State private var remindersOn = BookingReminders.isEnabled
    /// Session : profil pour reprogrammer les rappels.
    @Environment(AuthController.self) private var auth

    /// L'utilisateur a refusé les notifications dans les réglages d'iOS.
    private var systemDenied: Bool { systemStatus == .denied }

    /// Les deux interrupteurs, l'état de l'autorisation et l'erreur éventuelle.
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications")
                    .metaLabelStyle()

                // Propositions de parties (réglage du compte, en base).
                Toggle(isOn: preferenceBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Me proposer des parties sur mes créneaux habituels")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Quand une partie cherche un joueur à un moment où vous jouez souvent. Les messages importants, comme l'annulation d'une de vos parties, restent envoyés.")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                .tint(Brand.navy700)
                // Affiché désactivé plutôt que masqué : le membre comprend ce
                // qu'il manque, et où le rétablir.
                .disabled(!isLoaded || isSaving || systemDenied)

                Divider().opacity(0.4)

                // Rappels de réservation (réglage de l'appareil).
                Toggle(isOn: remindersBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rappel avant mes réservations")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Une notification une heure avant chaque réservation ou partie.")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                .tint(Brand.navy700)
                .disabled(systemDenied)

                // Notifications refusées : explication et lien vers les
                // Réglages de l'app.
                if systemDenied {
                    InlineMessage(kind: .info, message: "Les notifications sont désactivées pour iClub dans les réglages de l'iPhone.")
                    Button("Ouvrir Réglages") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.navy700)
                } else if systemStatus == .notDetermined, isOn {
                    // Geste explicite du membre : on peut présenter la demande
                    // système, qui n'a encore jamais été posée.
                    Button("Activer les notifications sur cet iPhone") {
                        Task {
                            await PushService.requestSystemAuthorization()
                            await refreshSystemStatus()
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.navy700)
                }

                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }
            }
        }
        // À l'affichage : autorisation du système, puis réglage du compte (en
        // cas d'échec de lecture, la valeur par défaut reste affichée).
        .task {
            await refreshSystemStatus()
            if let value = try? await PushService.loadPreference(profileId: profileId) {
                isOn = value
            }
            isLoaded = true
        }
        // Revenir des Réglages change peut-être l'autorisation.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshSystemStatus() }
        }
    }

    /// Interrupteur des propositions de parties : optimiste, il bascule tout
    /// de suite, écrit `profiles.notifications_parties`, et revient en arrière
    /// avec un message si l'écriture échoue.
    private var preferenceBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                let previous = isOn
                isOn = newValue
                isSaving = true
                errorMessage = nil
                Task {
                    do {
                        try await PushService.savePreference(newValue, profileId: profileId)
                        Haptics.selection()
                    } catch {
                        isOn = previous
                        errorMessage = "Réglage non enregistré. Vérifiez votre connexion et réessayez."
                        Haptics.failure()
                    }
                    isSaving = false
                }
            }
        )
    }

    /// Réglage de l'appareil : les rappels sont programmés sur le téléphone.
    ///
    /// Activé : les réservations du membre sont relues et les rappels
    /// reprogrammés. Désactivé : tous les rappels de réservation en attente
    /// sont retirés.
    private var remindersBinding: Binding<Bool> {
        Binding(
            get: { remindersOn },
            set: { newValue in
                remindersOn = newValue
                BookingReminders.isEnabled = newValue
                Haptics.selection()
                Task {
                    if newValue, let profile = auth.sessionProfile {
                        await BookingReminders.refresh(for: profile)
                    } else {
                        await BookingReminders.clear()
                    }
                }
            }
        )
    }

    /// Relit l'autorisation des notifications accordée par iOS.
    private func refreshSystemStatus() async {
        systemStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
