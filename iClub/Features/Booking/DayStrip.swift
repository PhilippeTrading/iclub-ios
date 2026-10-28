//
//  DayStrip.swift
//  iClub
//
//  Bande de jours défilable horizontalement, d'aujourd'hui jusqu'à l'horizon de
//  réservation du club. La plage vient de `club_sport_settings.horizon_jours` et
//  change donc avec le sport : jamais de nombre de jours codé en dur.
//

import SwiftUI

struct DayStrip: View {
    let days: [Date]
    /// Accent du sport courant, pour que la bande change de teinte avec l'onglet.
    let accent: Color
    @Binding var selection: Date
    /// Jours sélectionnables. Les autres restent visibles, estompés : la
    /// semaine garde sa continuité, sans promettre ce qu'elle n'a pas.
    var isEnabled: (Date) -> Bool = { _ in true }

    private let calendar = Calendar.current

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
            .onChange(of: selection) { _, day in
                // Couvre aussi le repli automatique sur aujourd'hui quand le
                // sport choisi a un horizon plus court que le jour sélectionné.
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(day, anchor: .center)
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let isEnabled = isEnabled(day)

        return Button {
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
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? accent : Brand.surface)
            }
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
        .id(day)
        .accessibilityLabel(day.longFrenchDate)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension DayStrip {

    /// Jours réservables : aujourd'hui inclus, puis l'horizon annoncé par le club.
    static func days(horizonJours: Int, from reference: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let horizon = max(0, horizonJours)

        return (0...horizon).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
    }
}

#Preview {
    @Previewable @State var selection = Calendar.current.startOfDay(for: .now)

    return DayStrip(
        days: DayStrip.days(horizonJours: 7),
        accent: Sport.tennis.accent,
        selection: $selection
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.background)
}
