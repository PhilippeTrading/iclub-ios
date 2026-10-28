//
//  ActivityCard.swift
//  iClub
//
//  Une activité dans la liste : nom, horaire habituel, terrain, entraîneur,
//  places, tarif indicatif, public visé et prochaine séance.
//

import SwiftUI

struct ActivityCard: View {
    let activity: Activity
    let courtName: String?
    let coachName: String?
    let placesLabel: String
    let nextSession: ActivitySession?
    let isEnrolled: Bool
    /// Statut affiché côté entraîneur (« En attente du club »…).
    var showsStatus = false

    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if let schedule = scheduleLine {
                    detailRow("clock", schedule)
                }
                if let coachName {
                    detailRow("person.crop.circle", coachName)
                }

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

            if isEnrolled {
                BrandChip(title: "Inscrit", systemImage: "checkmark", tint: Brand.success)
                    .fixedSize()
            } else if showsStatus {
                BrandChip(title: activity.statut.label, tint: statusTint)
                    .fixedSize()
            }
        }
    }

    private var statusTint: Color {
        switch activity.statut {
        case .proposee: Brand.warning
        case .ouverte: Brand.success
        default: Brand.textSecondary
        }
    }

    /// « Mercredi · 14h00 · Court 3 ».
    private var scheduleLine: String? {
        let parts = [activity.usualSchedule, courtName ?? activity.lieu].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tranche d'âge ou niveau, quand l'activité en fixe un.
    private var audience: String? {
        [activity.ageLabel, activity.levelLabel].compactMap { $0 }.first
    }

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

extension String {
    /// « Aujourd'hui » → « aujourd'hui », « Samedi 24 octobre » → « samedi
    /// 24 octobre » : au milieu d'une phrase, le jour ne prend pas de majuscule.
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
