//
//  PlayerProfileSheet.swift
//  iClub
//
//  Fiche d'un joueur, ouverte au tap sur sa vignette.
//
//  Photo, prénom et nom, âge, classement tennis, classement padel. **Rien
//  d'autre** : ni téléphone, ni e-mail, ni date de naissance. Ce n'est pas une
//  omission d'affichage, c'est ce que la fonction `get_club_roster_info`
//  accepte de renvoyer : les règles de sécurité interdisent de lire la fiche
//  d'un autre membre.
//
//  Un champ non renseigné affiche « Non renseigné », jamais un vide.
//
//  Place dans l'application
//    Feuille en demi-hauteur présentée par `OpenGamesView` quand on touche la
//    vignette d'un joueur (`PlayerSlotView`). Ce fichier déclare aussi
//    `SidePickerSheet`, le choix de la position au padel avant de rejoindre
//    une partie.
//
//  Données
//    Aucune lecture ici : la fiche (`RosterInfoRow`) est celle déjà chargée par
//    `OpenGamesStore` ; l'âge est calculé par la base à partir de la date de
//    naissance, qui n'est jamais transmise.
//

import SwiftUI

/// Fiche en lecture seule d'un joueur d'une partie ouverte.
struct PlayerProfileSheet: View {
    /// Joueur touché (nom affiché et initiales de repli).
    let player: OpenGame.Player
    /// Fiche du joueur, `nil` si `get_club_roster_info` n'a rien rendu.
    let info: RosterInfoRow?

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Photo, nom, puis la carte des trois informations, en demi-feuille.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Grande photo, ou initiales.
                    MemberAvatar(
                        url: info?.avatarUrl.flatMap(URL.init(string:)),
                        initials: info?.initials ?? player.initials,
                        size: 110
                    )
                    .padding(.top, 8)

                    // Prénom et nom de la fiche, à défaut le nom affiché dans
                    // la partie.
                    Text(info?.displayName ?? player.displayName)
                        .font(.editorial(.title2))
                        .foregroundStyle(Brand.navy800)
                        .multilineTextAlignment(.center)

                    // Les trois seules informations montrées, quel que soit le
                    // sport de la partie.
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

    /// « 34 ans », ou « Non renseigné » si l'âge est inconnu.
    private var ageLabel: String {
        guard let age = info?.age, age > 0 else { return "Non renseigné" }
        return "\(age) ans"
    }

    /// Ligne « libellé, valeur » de la fiche ; une valeur non renseignée est
    /// affichée en gris.
    ///
    /// - Parameters:
    ///   - label: intitulé de la ligne.
    ///   - value: valeur, ou « Non renseigné ».
    /// - Returns: la ligne, lue d'un bloc par VoiceOver.
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
///
/// Présentée par `OpenGamesView` après les contrôles d'admission ; choisir une
/// position ferme la feuille et lance l'adhésion (fonction SQL
/// `join_open_game`, qui reçoit l'équipe et le côté).
struct SidePickerSheet: View {
    /// Équipe visée, rappelée dans l'en-tête. `nil` en simple.
    let team: Team?
    /// Couleur du sport, pour les pictogrammes.
    let accent: Color
    /// Appelé avec la position choisie, avant la fermeture.
    let onPick: (Side) -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Rappel de l'équipe, question, puis une rangée par position.
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                // Rappel de l'équipe visée. Limite connue : `lowercased()`
                // passe aussi la lettre de l'équipe en minuscule
                // (« l'équipe a »).
                if let team {
                    Text("Tu rejoins l'\(team.displayName.lowercased())")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                Text("Quelle position ?")
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                // Une rangée par position : gauche, droite, indifférent.
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
                // Abandon : rien n'est envoyé.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        // Hauteur fixe de 340 points : juste de quoi montrer les trois choix.
        .presentationDetents([.height(340)])
    }

    /// Pictogramme d'une position.
    ///
    /// - Parameter side: position.
    /// - Returns: le nom du symbole SF (flèche gauche, droite, ou double).
    private func symbol(for side: Side) -> String {
        switch side {
        case .gauche: "arrow.left"
        case .droite: "arrow.right"
        case .indifferent: "arrow.left.arrow.right"
        }
    }
}
