//
//  DayStrip.swift
//  iClub
//
//  Bande de jours défilable horizontalement, d'aujourd'hui jusqu'à l'horizon de
//  réservation du club. La plage vient de `club_sport_settings.horizon_jours` et
//  change donc avec le sport : jamais de nombre de jours codé en dur.
//
//  Place dans l'application
//    `BookingView` (choix du jour d'une réservation), la création d'une partie
//    ouverte (`OpenGameCreateFlow`) et la liste des parties ouvertes
//    (`OpenGamesView`, qui grise les jours sans partie grâce à `isEnabled`).
//
//  Règles
//    Les jours proposés vont d'aujourd'hui inclus à aujourd'hui plus
//    `horizon_jours` inclus, dans le fuseau de l'appareil. L'horizon n'est
//    appliqué que par l'app : la base n'empêche pas une réservation plus
//    lointaine.
//

import SwiftUI

/// Rangée défilante de pastilles de jour (« LUN. 22 »), avec le jour choisi
/// en couleur pleine et aujourd'hui souligné d'un filet.
struct DayStrip: View {
    /// Jours affichés, à minuit (début de journée), dans l'ordre.
    let days: [Date]
    /// Accent du sport courant, pour que la bande change de teinte avec l'onglet.
    let accent: Color
    /// Jour sélectionné ; comparé aux pastilles au jour près.
    @Binding var selection: Date
    /// Jours sélectionnables. Les autres restent visibles, estompés : la
    /// semaine garde sa continuité, sans promettre ce qu'elle n'a pas.
    /// Tous sélectionnables par défaut.
    var isEnabled: (Date) -> Bool = { _ in true }

    /// Calendrier de l'appareil, pour les comparaisons au jour près.
    private let calendar = Calendar.current

    /// Rangée défilante des pastilles, recentrée sur le jour choisi.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        dayButton(day)
                    }
                }
                // Marge intérieure alignée sur celle de l'écran : les pastilles
                // défilent jusqu'au bord sans être rognées au repos.
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            // Le jour choisi est ramené au centre de la bande.
            .onChange(of: selection) { _, day in
                // Couvre aussi le repli automatique sur aujourd'hui quand le
                // sport choisi a un horizon plus court que le jour sélectionné.
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(day, anchor: .center)
                }
            }
        }
    }

    /// Une pastille de jour : abréviation du jour de la semaine et numéro.
    ///
    /// - Parameter day: jour représenté.
    /// - Returns: le bouton de la pastille, désactivé et estompé si
    ///   `isEnabled` refuse ce jour.
    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let isEnabled = isEnabled(day)

        return Button {
            // Toucher le jour déjà choisi ne fait rien.
            guard !isSelected else { return }
            selection = day
            Haptics.selection()
        } label: {
            VStack(spacing: 3) {
                Text(day.frenchWeekdayAbbreviation)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Brand.textSecondary)

                Text(day.frenchDayNumber)
                    .font(.numeral(.title2))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : Brand.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // `minWidth` plutôt qu'une largeur fixe : aux tailles
            // d'accessibilité la pastille s'élargit au lieu de rogner le texte.
            .frame(minWidth: 62)
            // Fond de la couleur du sport pour le jour choisi.
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? accent : Brand.surface)
            }
            // Filet : plus épais et teinté pour aujourd'hui, fin sinon, absent
            // sur le jour choisi.
            .overlay {
                RoundedRectangle.squircle(Radius.chip)
                    .strokeBorder(
                        isSelected ? .clear : (isToday ? accent.opacity(0.45) : Brand.hairline),
                        lineWidth: isToday ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        // Identifiant de défilement, utilisé par `scrollTo`.
        .id(day)
        .accessibilityLabel(day.longFrenchDate)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Calcul de la liste des jours, partagé par tous les écrans qui posent une
/// bande de jours.
extension DayStrip {

    /// Jours réservables : aujourd'hui inclus, puis l'horizon annoncé par le club.
    ///
    /// - Parameters:
    ///   - horizonJours: nombre de jours réservables après aujourd'hui
    ///     (`club_sport_settings.horizon_jours`) ; une valeur négative vaut 0.
    ///   - reference: instant de référence, maintenant par défaut.
    /// - Returns: `horizonJours + 1` dates, chacune au début de sa journée
    ///   (fuseau de l'appareil).
    static func days(horizonJours: Int, from reference: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let horizon = max(0, horizonJours)

        return (0...horizon).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
    }
}

/// Aperçu Xcode d'une bande de huit jours (horizon de 7 jours).
#Preview {
    // Jour choisi, modifiable dans l'aperçu ; aujourd'hui au départ.
    @Previewable @State var selection = Calendar.current.startOfDay(for: .now)

    return DayStrip(
        days: DayStrip.days(horizonJours: 7),
        accent: Sport.tennis.accent,
        selection: $selection
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.background)
}
