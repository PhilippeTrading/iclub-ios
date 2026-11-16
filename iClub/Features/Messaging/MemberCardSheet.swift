//
//  MemberCardSheet.swift
//  iClub
//
//  Rôle
//    La fiche d'un membre, ouverte depuis sa photo ou son nom dans une
//    conversation.
//
//    Seul ce qu'un membre peut voir d'un autre y figure : photo, prénom et nom,
//    âge, classements (`get_club_roster_info`). Le téléphone et l'e-mail ne sont
//    pas lisibles par les autres membres : c'est voulu, et la fiche n'essaie pas
//    de les contourner.
//
//  Place dans l'application
//    Feuille présentée par ConversationView (photo ou nom d'un auteur, avatar
//    de l'autre personne dans la barre) et par la liste des membres d'un
//    groupe. Son bouton « Envoyer un message privé » ouvre la conversation à
//    deux dans la feuille de messagerie.
//
//  Données
//    Fonction SQL `get_club_roster_info`, réservée aux membres du même club ;
//    en attendant sa réponse (ou si elle échoue), le nom et la photo connus
//    de la conversation servent de repli.
//

import SwiftUI

/// Fiche d'un membre vue par un autre membre.
struct MemberCardSheet: View {
    /// Identifiant du profil affiché.
    let profileId: UUID
    /// Nom affiché tant que la fiche n'est pas chargée (celui de la
    /// conversation).
    let fallbackName: String
    /// Photo de repli, celle de la conversation.
    let fallbackAvatar: URL?
    /// Affiche le bouton « Envoyer un message privé ». Faux quand la fiche est
    /// ouverte depuis la conversation à deux avec cette même personne.
    var canWritePrivately = true

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss
    /// Session : pour ne pas proposer de s'écrire à soi-même.
    @Environment(AuthController.self) private var auth
    /// Messagerie, pour ouvrir la conversation privée.
    @Environment(MessagingCenter.self) private var messaging

    /// Fiche chargée par `get_club_roster_info`, ou `nil`.
    @State private var info: RosterInfoRow?
    /// Ouverture de la conversation en cours : bouton désactivé.
    @State private var isOpening = false

    /// Nom de la fiche, sinon celui de repli.
    private var name: String { info?.displayName ?? fallbackName }
    /// Photo de la fiche, sinon celle de repli.
    private var avatar: URL? { info?.avatarUrl.flatMap(URL.init(string:)) ?? fallbackAvatar }

    /// Initiales de la fiche, sinon celles des deux premiers mots du nom de
    /// repli, sinon « ? ».
    private var initials: String {
        if let info { return info.initials }
        let value = fallbackName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    /// Photo, nom, âge, classements, bouton de message privé et mention de
    /// confidentialité.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Identité ; l'âge seulement s'il est connu.
                    VStack(spacing: 10) {
                        AvatarView(url: avatar, initials: initials, size: 120)
                        Text(name)
                            .font(.editorial(.title2))
                            .foregroundStyle(Brand.navy800)
                            .multilineTextAlignment(.center)
                        if let age = info?.age {
                            Text("\(age) ans")
                                .font(.subheadline)
                                .foregroundStyle(Brand.textSecondary)
                        }
                    }

                    // Classements, une fois la fiche chargée.
                    if let info {
                        rankingsCard(info)
                    }

                    // Message privé : jamais à soi-même.
                    if canWritePrivately && profileId != auth.sessionProfile?.id {
                        Button {
                            writePrivately()
                        } label: {
                            Label("Envoyer un message privé", systemImage: "bubble.left.fill")
                                .font(.system(.headline, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Brand.navy700)
                        .disabled(isOpening)
                    }

                    Text("Son téléphone et son e-mail ne sont pas partagés avec les autres membres.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(Brand.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
            }
        }
        // Assez haute pour montrer le bouton et la mention en entier : à mi-écran,
        // le bouton était coupé par le bas.
        .presentationDetents([.fraction(0.75), .large])
        // Lecture tolérante : sans réponse, la fiche garde le repli.
        .task {
            info = await ClubDirectoryService.rosterInfo(profileIds: [profileId])[profileId]
        }
    }

    /// Carte « Classements » : tennis et padel, « Non renseigné » à défaut.
    /// - Parameter info: la fiche chargée.
    /// - Returns: la carte.
    private func rankingsCard(_ info: RosterInfoRow) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                ProfileCardHeader(title: "Classements")
                LabeledContent("Tennis", value: info.tennisLabel)
                LabeledContent("Padel", value: info.padelLabel)
            }
            .font(.subheadline)
        }
    }

    /// Ouvre (ou retrouve) la conversation à deux, dans la même feuille.
    ///
    /// La fiche se ferme d'abord ; MessagingCenter remplace ensuite la pile de
    /// la feuille de messagerie par la nouvelle conversation.
    private func writePrivately() {
        isOpening = true
        Task {
            dismiss()
            await messaging.startConversation(with: profileId)
            isOpening = false
        }
    }
}
