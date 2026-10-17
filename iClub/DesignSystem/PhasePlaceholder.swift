//
//  PhasePlaceholder.swift
//  iClub
//
//  Coquille d'écran utilisée tant que la fonctionnalité correspondante n'est pas
//  construite. Reprend la direction artistique définitive pour que le rendu
//  visuel soit validable dès maintenant.
//

import SwiftUI

struct PhasePlaceholder: View {
    let systemImage: String
    let title: String
    let message: String
    var accent: Color = Brand.navy700

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 88, height: 88)
                .background(accent.opacity(0.10), in: .circle)

            VStack(spacing: 8) {
                Text(title)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.textPrimary)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .surfaceCard()
        .padding(.horizontal, 20)
    }
}

#Preview {
    ZStack {
        Brand.background.ignoresSafeArea()
        PhasePlaceholder(
            systemImage: "calendar.badge.plus",
            title: "Tunnel de réservation",
            message: "Choix du sport, planning 7 jours, participants et crédits invités.",
            accent: Brand.clay800
        )
    }
}
