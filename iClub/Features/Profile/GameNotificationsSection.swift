//
//  GameNotificationsSection.swift
//  iClub
//
//  « Me proposer des parties sur mes créneaux habituels ».
//
//  Écrit `profiles.notifications_parties`, distinct de l'autorisation système :
//  couper ces propositions ne coupe pas les messages importants, comme
//  l'annulation d'une partie où le membre est inscrit.
//

import SwiftUI
import UIKit
import UserNotifications

struct GameNotificationsSection: View {
    let profileId: UUID

    @Environment(\.scenePhase) private var scenePhase

    @State private var isOn = true
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var systemStatus: UNAuthorizationStatus = .notDetermined
    @State private var remindersOn = BookingReminders.isEnabled
    @Environment(AuthController.self) private var auth

    private var systemDenied: Bool { systemStatus == .denied }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications")
                    .metaLabelStyle()

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

    private func refreshSystemStatus() async {
        systemStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
