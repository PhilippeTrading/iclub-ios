//
//  NewMessageView.swift
//  iClub
//
//  Rôle
//    Recherche d'un membre du club pour lui écrire. `search_club_members` ne
//    renvoie que des membres du club, et `ouvrir_conversation` le revérifie.
//
//  Place dans l'application
//    Poussé dans la pile de la feuille de messagerie par le crayon « Nouveau
//    message » (route `NewMessageRoute`). Un tap sur un membre ouvre la
//    conversation à deux, qui remplace cet écran dans la pile
//    (MessagingCenter.startConversation).
//
//  Données
//    Fonction SQL `search_club_members` (ClubDirectoryService.searchMembers) :
//    au moins deux caractères, recherche sur le prénom ou le nom, huit
//    résultats au plus ; elle exclut l'utilisateur lui-même, les comptes
//    supprimés et les comptes d'enfants gérés par un parent.
//
//  États
//    Consigne « Tapez au moins 2 lettres » tant que la saisie est trop courte,
//    « Aucun membre trouvé. » si la recherche ne rend rien (ou échoue), sinon
//    la liste ; indicateur d'activité par-dessus pendant l'ouverture de la
//    conversation.
//

import SwiftUI

/// Recherche d'un destinataire pour un nouveau message.
struct NewMessageView: View {
    /// Session : club où chercher.
    @Environment(AuthController.self) private var auth
    /// Messagerie, pour ouvrir la conversation.
    @Environment(MessagingCenter.self) private var messaging

    /// Texte du champ de recherche.
    @State private var query = ""
    /// Membres trouvés pour la dernière recherche.
    @State private var results: [MemberSearchResult] = []
    /// Recherche en cours (évite d'afficher « Aucun membre trouvé » trop tôt).
    @State private var isSearching = false
    /// Ouverture de la conversation en cours : lignes désactivées.
    @State private var isOpening = false

    /// Consigne ou état vide, puis les membres trouvés ; champ de recherche
    /// toujours visible sous le titre.
    var body: some View {
        List {
            // Saisie trop courte : consigne (le seuil vient du modèle).
            if query.trimmingCharacters(in: .whitespaces).count < MemberSearchResult.minimumQueryLength {
                Text("Tapez au moins \(MemberSearchResult.minimumQueryLength) lettres du prénom ou du nom.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .listRowBackground(Color.clear)
            } else if results.isEmpty && !isSearching {
                // Recherche terminée sans résultat.
                Text("Aucun membre trouvé.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .listRowBackground(Color.clear)
            }

            // Un bouton par membre trouvé : photo (ou initiales) et nom.
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
        // Relancée à chaque frappe ; la frappe suivante annule la précédente
        // pendant son délai.
        .task(id: query) {
            // Petit délai : une requête par pause de frappe, pas par lettre.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let clubId = auth.sessionProfile?.clubId else { return }
            isSearching = true
            // Saisie trop courte : le service rend une liste vide sans
            // interroger la base. Un échec donne aussi une liste vide.
            results = (try? await ClubDirectoryService.searchMembers(clubId: clubId, query: query)) ?? []
            isSearching = false
        }
    }

    /// Ouvre (ou retrouve) la conversation à deux avec ce membre.
    /// - Parameter member: le membre choisi.
    private func open(_ member: MemberSearchResult) {
        isOpening = true
        Task {
            await messaging.startConversation(with: member.profileId)
            isOpening = false
        }
    }
}
