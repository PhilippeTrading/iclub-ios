//
//  ActivityCard.swift
//  iClub
//
//  Rôle
//    Une activité dans la liste : nom, horaire habituel, terrain, entraîneur,
//    places, tarif indicatif, public visé et prochaine séance.
//
//  Place dans l'application
//    Carte réutilisée par deux listes : l'onglet « Cours » côté membre
//    (ActivitiesView, avec la pastille « Inscrit ») et « Mes cours » côté
//    entraîneur (CoachSpaceView, avec le statut du cours : « En attente du
//    club », « En ligne »...). Vue sans état ni appel réseau : l'appelant lui
//    passe tout ce qu'elle affiche, déjà calculé par son magasin.
//
//  Accessibilité
//    Toute la carte est lue d'un bloc par VoiceOver (`children: .combine`).
//

import SwiftUI

/// Carte d'une activité dans une liste.
struct ActivityCard: View {
    /// L'activité affichée.
    let activity: Activity
    /// Nom du terrain habituel, résolu par l'appelant dans le catalogue ;
    /// `nil` : on affiche le lieu libre (`activites.lieu`) s'il existe.
    let courtName: String?
    /// Nom de l'entraîneur ou de l'encadrant ; `nil` : ligne masquée (c'est le
    /// cas dans « Mes cours », où l'entraîneur est l'utilisateur).
    let coachName: String?
    /// Libellé de la pastille des places, calculé par le magasin
    /// (« 8 places », « Complet », « 6 inscrits sur 8 »...).
    let placesLabel: String
    /// Prochaine séance prévue, ou `nil` s'il n'y en a aucune.
    let nextSession: ActivitySession?
    /// Vrai si le profil courant est inscrit ou en liste d'attente : pastille
    /// verte « Inscrit » en haut à droite.
    let isEnrolled: Bool
    /// Statut affiché côté entraîneur (« En attente du club »…).
    var showsStatus = false

    /// En-tête, horaire, entraîneur, pastilles, puis prochaine séance et tarif.
    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header

                // Horaire habituel et lieu, s'ils sont connus.
                if let schedule = scheduleLine {
                    detailRow("clock", schedule)
                }
                // Entraîneur ou encadrant, s'il est connu.
                if let coachName {
                    detailRow("person.crop.circle", coachName)
                }

                // Pastille des places (grise quand c'est complet, sinon couleur
                // du sport) et, s'il y en a un, public visé (âge ou niveau).
                HStack(spacing: 6) {
                    BrandChip(
                        title: placesLabel,
                        tint: activity.isFull ? Brand.textSecondary : activity.sport.accent
                    )
                    .fixedSize()
                    if let audience {
                        BrandChip(title: audience, tint: Brand.navy700)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                // Pied de carte : prochaine séance à gauche, tarif à droite,
                // affiché dès que l'un des deux existe.
                if activity.priceLabel != nil || nextSession != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if let nextSession {
                            Text("Prochaine séance : \(nextSession.date.relativeFrenchDayTitle.lowercasedFirst) à \(nextSession.slot.startLabel)")
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if let price = activity.priceLabel {
                            Text(price)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Icône du sport dans un disque teinté, nom et type de l'activité, et à
    /// droite la pastille « Inscrit » ou, côté entraîneur, le statut.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activity.sport.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(activity.sport.accent)
                .frame(width: 36, height: 36)
                .background(activity.sport.accent.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.nom)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(2)
                Text(activity.type.singularLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }

            Spacer(minLength: 8)

            // « Inscrit » l'emporte sur le statut ; sans l'un ni l'autre, rien.
            if isEnrolled {
                BrandChip(title: "Inscrit", systemImage: "checkmark", tint: Brand.success)
                    .fixedSize()
            } else if showsStatus {
                BrandChip(title: activity.statut.label, tint: statusTint)
                    .fixedSize()
            }
        }
    }

    /// Couleur de la pastille de statut : orange pour un cours en attente de
    /// validation par le club, vert en ligne, gris pour les autres statuts.
    private var statusTint: Color {
        switch activity.statut {
        case .proposee: Brand.warning
        case .ouverte: Brand.success
        default: Brand.textSecondary
        }
    }

    /// « Mercredi · 14h00 · Court 3 ».
    ///
    /// Horaire habituel (colonnes libres `jour` et `heure`), puis le nom du
    /// terrain, ou à défaut le lieu libre. `nil` si rien n'est connu.
    private var scheduleLine: String? {
        let parts = [activity.usualSchedule, courtName ?? activity.lieu].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tranche d'âge ou niveau, quand l'activité en fixe un.
    ///
    /// L'âge passe avant le niveau : une seule pastille est affichée.
    private var audience: String? {
        [activity.ageLabel, activity.levelLabel].compactMap { $0 }.first
    }

    /// Ligne d'information avec une petite icône grise.
    /// - Parameters:
    ///   - symbol: nom du symbole SF Symbols.
    ///   - text: texte affiché sur une seule ligne.
    /// - Returns: l'étiquette composée.
    private func detailRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Brand.textPrimary)
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

/// Outil de texte partagé par les écrans d'activités et l'historique des
/// notifications.
extension String {
    /// « Aujourd'hui » → « aujourd'hui », « Samedi 24 octobre » → « samedi
    /// 24 octobre » : au milieu d'une phrase, le jour ne prend pas de majuscule.
    ///
    /// Utilisé ici pour « Prochaine séance : demain à 17 h 00 », et partout où
    /// un titre de jour entre dans une phrase.
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
