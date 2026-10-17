//
//  SlotRow.swift
//  iClub
//
//  Vignette d'un créneau disponible : pleine largeur, deux lignes, faible
//  hauteur. Une rangée de liste généreuse, pas une carte.
//
//  Ligne 1 : l'horaire, en évidence.
//  Ligne 2 : les terrains libres à cet horaire, sur une seule ligne. Le nombre
//  de noms est plafonné et suivi d'un « +N » : le compte affiché à droite garde
//  l'information exacte même quand la liste est écourtée.
//

import SwiftUI

struct SlotRow: View {
    let slot: TimeSlot
    /// Terrains disponibles, dans l'ordre `courts.ordre`.
    let courts: [Court]
    let accent: Color
    /// `nil` quand le membre a une adhésion active : aucun prix n'est affiché.
    let priceLabel: String?

    /// Au-delà, la liste des noms est écourtée par un « +N ».
    private static let maxVisibleNames = 3

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.label)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)

                Text(courtSummary)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(countLabel)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent)
                    .fixedSize()

                if let priceLabel {
                    Text(priceLabel)
                        .font(.caption2)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize()
                }
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Radius.inner)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.label), \(countLabel)")
        .accessibilityHint("Choisir un terrain")
    }

    /// « Central · Tennis 1 · Tennis 3 +2 »
    private var courtSummary: String {
        let names = courts.map(\.nom)
        let visible = names.prefix(Self.maxVisibleNames)
        let hidden = names.count - visible.count

        let joined = visible.joined(separator: " · ")
        return hidden > 0 ? "\(joined) +\(hidden)" : joined
    }

    private var countLabel: String {
        courts.count > 1 ? "\(courts.count) dispos" : "1 dispo"
    }
}

#Preview {
    func court(_ nom: String, _ ordre: Int) -> Court {
        Court(
            id: UUID(), clubId: UUID(), nom: nom, sport: .tennis,
            surface: "Terre battue", eclaire: true, couvert: false,
            tarifPrixTotal: 25, tarifCapacite: 2,
            dureeCreneauMinutes: 60, ordre: ordre
        )
    }

    let many = ["Central", "Tennis 1", "Tennis 3", "Tennis 7", "Terbal A"]
        .enumerated().map { court($1, $0) }

    return VStack(spacing: 8) {
        SlotRow(
            slot: TimeSlot(startMinutes: 14 * 60, durationMinutes: 60),
            courts: many,
            accent: Sport.tennis.accent,
            priceLabel: "12,50 €"
        )

        SlotRow(
            slot: TimeSlot(startMinutes: 15 * 60, durationMinutes: 60),
            courts: [court("Tennis 12", 0)],
            accent: Sport.tennis.accent,
            priceLabel: nil
        )

        SlotRow(
            slot: TimeSlot(startMinutes: 18 * 60, durationMinutes: 90),
            courts: Array(many.prefix(2)),
            accent: Sport.padel.accent,
            priceLabel: "dès 10,00 €"
        )
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.background)
}
