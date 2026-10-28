//
//  NewMessageView.swift
//  iClub
//
//  Recherche d'un membre du club pour lui écrire. `search_club_members` ne
//  renvoie que des membres du club, et `ouvrir_conversation` le revérifie.
//

import SwiftUI

struct NewMessageView: View {
    @Environment(AuthController.self) private var auth
    @Environment(MessagingCenter.self) private var messaging

    @State private var query = ""
    @State private var results: [MemberSearchResult] = []
    @State private var isSearching = false
    @State private var isOpening = false

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).count < MemberSearchResult.minimumQueryLength {
                Text("Tapez au moins \(MemberSearchResult.minimumQueryLength) lettres du prénom ou du nom.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .listRowBackground(Color.clear)
            } else if results.isEmpty && !isSearching {
                Text("Aucun membre trouvé.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(results) { member in
                Button {
                    open(member)
                } label: {
                    HStack(spacing: 12) {
                        MemberAvatar(url: member.avatarUrl.flatMap(URL.init(string:)), initials: member.initials, size: 38)
                        Text(member.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Spacer()
                    }
                }
                .disabled(isOpening)
                .listRowBackground(Brand.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Nouveau message")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher un membre")
        .overlay { if isOpening { ProgressView() } }
        .task(id: query) {
            // Petit délai : une requête par pause de frappe, pas par lettre.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let clubId = auth.sessionProfile?.clubId else { return }
            isSearching = true
            results = (try? await ClubDirectoryService.searchMembers(clubId: clubId, query: query)) ?? []
            isSearching = false
        }
    }

    private func open(_ member: MemberSearchResult) {
        isOpening = true
        Task {
            await messaging.startConversation(with: member.profileId)
            isOpening = false
        }
    }
}
