//
//  PlayerProfileSheet.swift
//  iClub
//
//  Fiche d'un joueur, ouverte au tap sur sa vignette.
//
//  Photo, prénom et nom, âge, classement tennis, classement padel. **Rien
//  d'autre** : ni téléphone, ni e-mail, ni date de naissance. Ce n'est pas une
//  omission d'affichage, c'est ce que la fonction `get_club_roster_info`
//  accepte de renvoyer — les règles de sécurité interdisent de lire la fiche
//  d'un autre membre.
//
//  Un champ non renseigné affiche « Non renseigné », jamais un vide.
//

import SwiftUI

struct PlayerProfileSheet: View {
    let player: OpenGame.Player
    let info: RosterInfoRow?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    MemberAvatar(
                        url: info?.avatarUrl.flatMap(URL.init(string:)),
                        initials: info?.initials ?? player.initials,
                        size: 110
                    )
                    .padding(.top, 8)

                    Text(info?.displayName ?? player.displayName)
                        .font(.editorial(.title2))
                        .foregroundStyle(Brand.navy800)
                        .multilineTextAlignment(.center)

                    SurfaceCard {
                        VStack(spacing: 0) {
                            row(label: "Âge", value: ageLabel)
                            Divider().opacity(0.4)
                            row(label: "Classement tennis", value: info?.tennisLabel ?? "Non renseigné")
                            Divider().opacity(0.4)
                            row(label: "Classement padel", value: info?.padelLabel ?? "Non renseigné")
                        }
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Joueur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var ageLabel: String {
        guard let age = info?.age, age > 0 else { return "Non renseigné" }
        return "\(age) ans"
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(value == "Non renseigné" ? Brand.textSecondary : Brand.textPrimary)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}

/// Choix de la position avant de rejoindre. **Padel uniquement.**
struct SidePickerSheet: View {
    /// Équipe visée, rappelée dans l'en-tête. `nil` en simple.
    let team: Team?
    let accent: Color
    let onPick: (Side) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let team {
                    Text("Tu rejoins l'\(team.displayName.lowercased())")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                Text("Quelle position ?")
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                ForEach(Side.allCases) { side in
                    Button {
                        onPick(side)
                        Haptics.selection()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: side))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(accent)
                                .frame(width: 26)

                            Text(side.displayName)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.textSecondary.opacity(0.6))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surfaceCard(cornerRadius: Radius.inner)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(340)])
    }

    private func symbol(for side: Side) -> String {
        switch side {
        case .gauche: "arrow.left"
        case .droite: "arrow.right"
        case .indifferent: "arrow.left.arrow.right"
        }
    }
}
