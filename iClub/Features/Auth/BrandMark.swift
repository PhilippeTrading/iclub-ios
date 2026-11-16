//
//  BrandMark.swift
//  iClub
//
//  Rôle
//    Logo de l'application : pictogramme de joueur de tennis dans une pastille
//    en verre, mot « iClub » et mention « Espace membre ». Composant purement
//    visuel, sans donnée ni action.
//
//  Place dans l'application
//    En tête de l'écran de connexion (`SignInView`) et au centre de l'écran de
//    lancement (`LaunchView`, dans RootView.swift).
//

import SwiftUI

/// Signature visuelle du club sur les écrans d'authentification.
///
/// Pour VoiceOver, l'ensemble se lit comme un seul élément : « iClub, espace
/// membre ».
struct BrandMark: View {
    /// Pastille du pictogramme, puis le nom et la mention, empilés.
    var body: some View {
        VStack(spacing: 14) {
            // Pastille en verre de 84 points avec le pictogramme.
            Image(systemName: "figure.tennis")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)

            // Nom de l'application et mention de l'espace.
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

/// Aperçu Xcode du logo sur le fond des écrans d'authentification.
#Preview {
    ZStack {
        AuroraBackground()
        BrandMark()
    }
}
