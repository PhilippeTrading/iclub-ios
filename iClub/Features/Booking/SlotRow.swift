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
//  Place dans l'application
//    Liste des créneaux de `BookingView` (écran 1 du tunnel de réservation),
//    et liste des créneaux de la création d'une partie ouverte. La rangée est
//    purement visuelle : le lien de navigation est posé par l'écran parent.
//
//  Prix
//    À droite, sous le nombre de terrains libres, le prix par joueur calculé
//    par `Price.label` (`tarif_prix_total / tarif_capacite`, « dès » quand les
//    terrains ont des tarifs différents), ou rien pour un membre à l'adhésion
//    active. Limite connue : ce prix ignore les plages tarifaires selon l'heure
//    et le jour que le planning web applique (`prixSelonPlages`).
//

import SwiftUI

/// Rangée d'un créneau libre : horaire, terrains libres, nombre et prix.
struct SlotRow: View {
    /// Créneau présenté (début et durée en minutes depuis minuit).
    let slot: TimeSlot
    /// Terrains disponibles, dans l'ordre `courts.ordre`.
    let courts: [Court]
    /// Couleur du sport, pour le nombre de terrains libres.
    let accent: Color
    /// `nil` quand le membre a une adhésion active : aucun prix n'est affiché.
    /// Sinon un libellé prêt à afficher (« 12,50 € », « dès 10,00 € »).
    let priceLabel: String?

    /// Au-delà, la liste des noms est écourtée par un « +N ».
    private static let maxVisibleNames = 3

    /// Rangée sur deux lignes, avec le nombre de terrains et le prix à droite.
    var body: some View {
        HStack(spacing: 12) {
            // Gauche : horaire, puis les noms des terrains libres.
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

            // Droite : « 3 dispos », puis le prix s'il doit être montré.
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
        // VoiceOver lit la rangée d'un bloc : horaire et nombre de terrains.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.label), \(countLabel)")
        .accessibilityHint("Choisir un terrain")
    }

    /// « Central · Tennis 1 · Tennis 3 +2 »
    /// Les trois premiers noms dans l'ordre des terrains, puis le nombre de
    /// terrains non nommés.
    private var courtSummary: String {
        let names = courts.map(\.nom)
        let visible = names.prefix(Self.maxVisibleNames)
        let hidden = names.count - visible.count

        let joined = visible.joined(separator: " · ")
        return hidden > 0 ? "\(joined) +\(hidden)" : joined
    }

    /// « 1 dispo » ou « 5 dispos ».
    private var countLabel: String {
        courts.count > 1 ? "\(courts.count) dispos" : "1 dispo"
    }
}

/// Aperçu Xcode : beaucoup de terrains (liste écourtée), un seul terrain sans
/// prix, et un créneau de padel de 90 minutes avec prix « dès ».
#Preview {
    /// Fabrique un terrain de tennis fictif.
    func court(_ nom: String, _ ordre: Int) -> Court {
        Court(
            id: UUID(), clubId: UUID(), nom: nom, sport: .tennis,
            surface: "Terre battue", eclaire: true, couvert: false,
            tarifPrixTotal: 25, tarifCapacite: 2,
            dureeCreneauMinutes: 60, ordre: ordre
        )
    }

    // Cinq terrains, dans l'ordre : de quoi écourter la liste des noms.
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
