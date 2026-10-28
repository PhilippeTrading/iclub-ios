//
//  MemberCardSheet.swift
//  iClub
//
//  La fiche d'un membre, ouverte depuis sa photo ou son nom dans une
//  conversation.
//
//  Seul ce qu'un membre peut voir d'un autre y figure : photo, prénom et nom,
//  âge, classements (`get_club_roster_info`). Le téléphone et l'e-mail ne sont
//  pas lisibles par les autres membres : c'est voulu, et la fiche n'essaie pas
//  de les contourner.
//

import SwiftUI

struct MemberCardSheet: View {
    let profileId: UUID
    let fallbackName: String
    let fallbackAvatar: URL?
    var canWritePrivately = true

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthController.self) private var auth
    @Environment(MessagingCenter.self) private var messaging

    @State private var info: RosterInfoRow?
    @State private var isOpening = false

    private var name: String { info?.displayName ?? fallbackName }
    private var avatar: URL? { info?.avatarUrl.flatMap(URL.init(string:)) ?? fallbackAvatar }

    private var initials: String {
        if let info { return info.initials }
        let value = fallbackName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
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

                    if let info {
                        rankingsCard(info)
                    }

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
        .task {
            info = await ClubDirectoryService.rosterInfo(profileIds: [profileId])[profileId]
        }
    }

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
    private func writePrivately() {
        isOpening = true
        Task {
            dismiss()
            await messaging.startConversation(with: profileId)
            isOpening = false
        }
    }
}
