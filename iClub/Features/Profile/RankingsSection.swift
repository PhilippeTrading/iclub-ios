//
//  RankingsSection.swift
//  iClub
//
//  Classements tennis et padel, consultables et modifiables par le membre.
//
//  Ce n'est pas un champ décoratif : le classement conditionne les parties
//  ouvertes qu'on peut créer ou rejoindre. Une valeur absente bloque le membre
//  partout, d'où la phrase d'explication sous les deux lignes.
//
//  Le pickleball n'apparaît pas : le club n'y tient aucun classement.
//

import SwiftUI

struct RankingsSection: View {
    let profile: SessionProfile
    /// Rechargement du profil de session après écriture, pour que la nouvelle
    /// valeur se propage à tous les écrans qui l'affichent.
    let onSaved: () async -> Void

    /// Sport dont l'enregistrement est en cours, pour n'afficher l'indicateur
    /// que sur la ligne concernée.
    @State private var savingSport: Sport?
    @State private var errorMessage: String?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Classements")
                    .metaLabelStyle()

                VStack(spacing: 0) {
                    tennisRow
                    Divider().opacity(0.4)
                    padelRow
                }

                Text("Votre classement conditionne les parties ouvertes que vous pouvez créer ou rejoindre.")
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)

                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }
            }
        }
    }

    // MARK: - Tennis

    private var tennisRow: some View {
        let binding = Binding<String?>(
            get: { profile.classementTennis },
            set: { save(tennis: $0) }
        )

        return row(sport: .tennis) {
            Picker("Classement tennis", selection: binding) {
                Text("Non renseigné").tag(String?.none)
                // L'ordre du tableau *est* la règle : « 15/2 » est plus fort
                // que « 30/5 », et rien dans les chaînes ne le dit.
                ForEach(Ranking.tennisScale, id: \.self) { value in
                    Text(value).tag(String?.some(value))
                }
            }
            .pickerStyle(.menu)
            .tint(Brand.navy700)
            .labelsHidden()
            // « Non renseigné » est bien plus large qu'une valeur d'échelle :
            // sans cela il se coupe en deux lignes et empiète sur la phrase
            // d'explication.
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: - Padel

    private var padelRow: some View {
        let binding = Binding<Double?>(
            get: { profile.classementPadel },
            set: { save(padel: $0) }
        )

        return row(sport: .padel) {
            Picker("Classement padel", selection: binding) {
                Text("Non renseigné").tag(Double?.none)
                ForEach(Ranking.padelScale, id: \.self) { value in
                    // Stocké avec un point, affiché avec une virgule.
                    Text(Ranking.display(Ranking.stored(padel: value), sport: .padel))
                        .tag(Double?.some(value))
                }
            }
            .pickerStyle(.menu)
            .tint(Brand.navy700)
            .labelsHidden()
            // « Non renseigné » est bien plus large qu'une valeur d'échelle :
            // sans cela il se coupe en deux lignes et empiète sur la phrase
            // d'explication.
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: - Ligne

    private func row(sport: Sport, @ViewBuilder picker: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sport.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(sport.accent)
                .frame(width: 22)

            Text(sport.displayName)
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)

            Spacer(minLength: 12)

            if savingSport == sport {
                ProgressView().controlSize(.small)
            } else {
                picker()
            }
        }
        .padding(.vertical, 6)
        .disabled(savingSport != nil)
    }

    // MARK: - Enregistrement

    private func save(tennis value: String?) {
        // Rien à faire si le choix retombe sur la valeur déjà enregistrée.
        guard value != profile.classementTennis else { return }
        perform(sport: .tennis) { try await ProfileService.updateTennisRanking(value) }
    }

    private func save(padel value: Double?) {
        guard value != profile.classementPadel else { return }
        perform(sport: .padel) { try await ProfileService.updatePadelRanking(value) }
    }

    /// L'affichage est piloté par `profile`, rechargé après écriture : en cas
    /// d'échec rien n'a bougé, l'ancienne valeur reste donc à l'écran sans
    /// qu'il y ait à la restaurer à la main.
    private func perform(sport: Sport, _ write: @escaping () async throws -> Void) {
        savingSport = sport
        errorMessage = nil

        Task {
            do {
                try await write()
                await onSaved()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            savingSport = nil
        }
    }
}

#Preview {
    func profile(tennis: String?, padel: Double?) -> SessionProfile {
        SessionProfile(
            id: UUID(), clubMemberId: UUID(), email: "membre@iclub.test",
            nom: "Dupont", prenom: "Marie", displayName: "Marie Dupont",
            avatarUrl: nil, telephone: nil, dateNaissance: nil, sexe: .femme,
            role: "membre", isAdmin: false, clubId: UUID(), clubName: "Club",
            classementTennis: tennis, classementPadel: padel,
            hasActiveMembership: true,
            activeMembershipPeriod: nil, activeMembershipDetails: nil
        )
    }

    return ScrollView {
        VStack(spacing: 16) {
            // Les deux renseignés, puis le cas « non renseigné ».
            RankingsSection(profile: profile(tennis: "30/1", padel: 2.5)) {}
            RankingsSection(profile: profile(tennis: "15/2", padel: nil)) {}
        }
        .padding(20)
    }
    .background(Brand.background)
}
