//
//  BrandMark.swift
//  iClub
//

import SwiftUI

/// Signature visuelle du club sur les écrans d'authentification.
struct BrandMark: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.tennis")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: 2) {
                Text("iClub")
                    .font(.editorial(.title, weight: .heavy))
                    .foregroundStyle(Brand.navy800)
                Text("Espace membre")
                    .metaLabelStyle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iClub, espace membre")
    }
}

#Preview {
    ZStack {
        AuroraBackground()
        BrandMark()
    }
}
