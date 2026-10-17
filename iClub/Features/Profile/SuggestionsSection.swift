//
//  SuggestionsSection.swift
//  iClub
//
//  « Me suggérer des parties », et son option de position.
//
//  Transparent au consentement, discret dans la notification : c'est ici, en
//  clair, que le membre apprend que sa position peut servir de filtre, à quoi,
//  et qu'elle ne quitte pas son téléphone. Les notifications, elles, ne
//  parleront que de la partie proposée.
//

import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

struct SuggestionsSection: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var isEnabled = ReengagementService.isEnabled
    @State private var usesLocation = ReengagementService.usesLocation
    @State private var isWorking = false
    @State private var notificationsDenied = false
    @State private var clubHasLocation = true

    private var zone: ZoneMonitor { .shared }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Suggestions de parties")
                    .metaLabelStyle()

                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Me suggérer des parties")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Si vous n'avez pas joué depuis un moment, nous vous proposons une partie ouverte qui vous correspond. Deux suggestions au plus, puis plus rien jusqu'à votre prochaine partie.")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                .tint(Brand.navy700)
                .disabled(isWorking)

                if notificationsDenied {
                    settingsNotice("Les notifications sont désactivées pour iClub. Autorisez-les dans Réglages pour recevoir des suggestions.")
                }

                if isEnabled {
                    Divider().opacity(0.4)
                    locationToggle
                }
            }
        }
        .task { clubHasLocation = await ReengagementService.clubCoordinate() != nil }
        // Revenir des Réglages change peut-être les autorisations.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: - Position

    @ViewBuilder
    private var locationToggle: some View {
        Toggle(isOn: locationBinding) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Seulement si je suis dans la région du club")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text("Utilise votre position pour ne pas vous déranger quand vous êtes loin, en vacances par exemple. Elle reste sur votre téléphone et n'est jamais envoyée au club.")
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
        .tint(Brand.navy700)
        .disabled(isWorking || !clubHasLocation)

        if !clubHasLocation {
            Text("Disponible dès que le club aura renseigné son adresse.")
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)
        } else if usesLocation {
            switch zone.authorization {
            case .authorizedAlways:
                EmptyView()
            case .authorizedWhenInUse:
                // Avec « Pendant l'utilisation », iOS ne dit rien quand l'app
                // est fermée : le filtre ne s'applique alors pas.
                settingsNotice("Pour que ce filtre fonctionne app fermée, choisissez « Toujours » dans Réglages › Position.")
            case .denied, .restricted:
                settingsNotice("La position est refusée pour iClub. Les suggestions restent actives, sans ce filtre.")
            default:
                EmptyView()
            }
        }
    }

    private func settingsNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineMessage(kind: .info, message: message)
            Button("Ouvrir Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Brand.navy700)
        }
    }

    // MARK: - Liaisons

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                isWorking = true
                Task {
                    if newValue {
                        let granted = await ReengagementService.enable()
                        isEnabled = granted
                        notificationsDenied = !granted
                    } else {
                        await ReengagementService.disable()
                        isEnabled = false
                        usesLocation = false
                    }
                    Haptics.selection()
                    isWorking = false
                }
            }
        )
    }

    private var locationBinding: Binding<Bool> {
        Binding(
            get: { usesLocation },
            set: { newValue in
                isWorking = true
                Task {
                    await ReengagementService.setUsesLocation(newValue)
                    usesLocation = newValue
                    Haptics.selection()
                    isWorking = false
                }
            }
        )
    }

    private func refreshNotificationStatus() async {
        guard isEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }
}
