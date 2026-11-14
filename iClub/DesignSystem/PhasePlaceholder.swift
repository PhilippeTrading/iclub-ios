//
//  PhasePlaceholder.swift
//  iClub
//
//  Rôle
//    Carte d'état d'écran : une icône dans un disque teinté, un titre et un
//    message centrés. Née comme coquille d'écran, affichée tant que la
//    fonctionnalité correspondante n'était pas construite (d'où son nom), elle
//    reprend la direction artistique définitive.
//
//  Place dans l'application
//    Elle sert aujourd'hui d'état vide ou d'état d'erreur dans la plupart des
//    écrans : « Aucun cours », « Aucune conversation », « Aucune réservation »,
//    « Aucune séance cette semaine », « Élève introuvable », « Cours
//    introuvable », « Terrain indisponible », etc. (voir les appels dans
//    Features/). La couleur `accent` dit la nature du message : bleu marine par
//    défaut, `Brand.warning` pour un avertissement, accent du sport quand
//    l'écran en dépend.
//

import SwiftUI

/// Carte centrée « icône, titre, message » pour un écran vide, indisponible ou
/// en erreur.
struct PhasePlaceholder: View {
    /// Nom d'un symbole SF Symbols affiché en grand dans le disque.
    let systemImage: String
    /// Titre court, en police éditoriale.
    let title: String
    /// Explication sur une ou plusieurs lignes, centrée, en texte secondaire.
    let message: String
    /// Teinte de l'icône et de son disque (à 10 % d'opacité). Bleu marine par
    /// défaut.
    var accent: Color = Brand.navy700

    /// Disque d'icône au-dessus du titre et du message, le tout dans une carte
    /// opaque à 20 points des bords de l'écran.
    var body: some View {
        VStack(spacing: 18) {
            // Icône fine de 34 points dans un disque teinté de 88 points.
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 88, height: 88)
                .background(accent.opacity(0.10), in: .circle)

            // Titre puis message explicatif.
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

/// Aperçu Xcode, avec l'accent terre battue du tennis.
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
