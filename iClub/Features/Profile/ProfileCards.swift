//
//  ProfileCards.swift
//  iClub
//
//  Cartes de l'onglet Profil alignées sur le web : adhésion, famille, reçus et
//  factures, autres espaces. Une carte qui n'a rien à dire se replie sur une
//  ligne, avec son action s'il y en a une.
//

import QuickLook
import SwiftUI

// MARK: - Carte repliable

/// En-tête de carte commun : titre en petites capitales, action à droite.
struct ProfileCardHeader<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack {
            Text(title).metaLabelStyle()
            Spacer(minLength: 8)
            action
        }
    }
}

extension ProfileCardHeader where Action == EmptyView {
    init(title: String) {
        self.title = title
        self.action = EmptyView()
    }
}

/// Une carte qui n'a qu'une ligne à dire.
struct CollapsedProfileCard<Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        SurfaceCard(padding: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).metaLabelStyle()
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer(minLength: 8)
                action
            }
        }
    }
}

extension CollapsedProfileCard where Action == EmptyView {
    init(title: String, message: String) {
        self.title = title
        self.message = message
        self.action = EmptyView()
    }
}

// MARK: - Badge d'adhésion (en-tête)

struct MembershipBadge: View {
    let profile: SessionProfile

    var body: some View {
        if let period = profile.activeMembershipPeriod {
            BrandChip(
                title: "Adhésion à jour jusqu'au \(period.fin.frenchDayMonthYear)",
                systemImage: "checkmark.seal.fill",
                tint: Brand.success
            )
        } else {
            BrandChip(title: "Aucune adhésion active", systemImage: "seal", tint: Brand.textSecondary)
        }
    }
}

// MARK: - Adhésion

struct MembershipSection: View {
    let profile: SessionProfile

    var body: some View {
        if let details = profile.activeMembershipDetails, let period = profile.activeMembershipPeriod {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    ProfileCardHeader(title: "Adhésion")
                    Text("\(details.formule) · \(Price.amount(details.montant))")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Du \(period.debut.frenchDayMonthYear) au \(period.fin.frenchDayMonthYear)")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            CollapsedProfileCard(title: "Adhésion", message: "Aucune adhésion active pour l'instant.") {
                NavigationLink {
                    MembershipFormulasView()
                } label: {
                    Text("Adhérer")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Reçus et factures

/// Dans le profil, une seule ligne qui mène à la liste complète : les reçus
/// s'accumulent saison après saison et prendraient tout l'écran.
struct ReceiptsSection: View {
    let receipts: [AccountingDocument]
    let clubSlug: String?

    var body: some View {
        if receipts.isEmpty {
            CollapsedProfileCard(title: "Reçus et factures", message: "Aucun document pour l'instant.")
        } else {
            NavigationLink {
                ReceiptsListView(receipts: receipts, clubSlug: clubSlug)
            } label: {
                SurfaceCard(padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Brand.navy700)
                            .frame(width: 36, height: 36)
                            .background(Brand.navy700.opacity(0.12), in: .circle)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reçus et factures").metaLabelStyle()
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(Brand.textSecondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// « 12 documents · le dernier le 18 sept. ».
    private var summary: String {
        let count = receipts.count == 1 ? "1 document" : "\(receipts.count) documents"
        guard let last = receipts.first?.emisLe else { return count }
        return "\(count) · le dernier le \(last.shortFrenchDate)"
    }
}

/// Tous les reçus, factures et avoirs du membre, du plus récent au plus ancien.
struct ReceiptsListView: View {
    let receipts: [AccountingDocument]
    let clubSlug: String?

    @State private var previewURL: URL?
    @State private var downloadingId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let errorMessage {
                    InlineMessage(kind: .info, message: errorMessage)
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(receipts) { receipt in
                            row(receipt)
                            if receipt.id != receipts.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Reçus et factures")
        .navigationBarTitleDisplayMode(.inline)
        // Aperçu QuickLook, avec son bouton de partage.
        .quickLookPreview($previewURL)
    }

    private func row(_ receipt: AccountingDocument) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: receipt.type.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.navy700)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.libelle)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(2)
                Text([receipt.type.label + " " + receipt.numero,
                      receipt.emisLe?.shortFrenchDate,
                      receipt.modePaiement].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)

                Button {
                    download(receipt)
                } label: {
                    if downloadingId == receipt.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Télécharger", systemImage: "arrow.down.doc")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.navy700)
                .padding(.top, 2)
                .disabled(downloadingId != nil || clubSlug == nil)
            }

            Spacer(minLength: 8)

            Text(Price.amount(receipt.montantTtc))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Brand.textPrimary)
        }
    }

    private func download(_ receipt: AccountingDocument) {
        guard let clubSlug else { return }
        downloadingId = receipt.id
        errorMessage = nil
        Task {
            do {
                previewURL = try await MemberDocumentsService.downloadPDF(receipt, clubSlug: clubSlug)
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadingId = nil
        }
    }
}

// MARK: - Autres espaces

/// Administrateurs et entraîneurs : leur espace web, ouvert dans Safari.
struct OtherSpacesRow: View {
    let profile: SessionProfile
    let clubSlug: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let clubSlug, profile.isAdmin || profile.isCoach {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vos autres espaces").metaLabelStyle()
                HStack(spacing: 10) {
                    if profile.isAdmin {
                        link("Back-office du club", systemImage: "building.columns", path: "admin", slug: clubSlug)
                    }
                    if profile.isCoach {
                        link("Espace entraîneur", systemImage: "figure.tennis", path: "coach", slug: clubSlug)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func link(_ title: String, systemImage: String, path: String, slug: String) -> some View {
        Button {
            if let url = URL(string: "https://\(slug).iclubapp.fr/\(path)") { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}

// MARK: - Dates

extension Date {
    /// « 1er septembre 2026 », « 31 août 2027 ».
    var frenchDayMonthYear: String {
        let day = Calendar.current.component(.day, from: self)
        let rest = formatted(Date.FormatStyle(date: .omitted, time: .omitted).month(.wide).year().locale(AppLocale.french))
        return "\(day == 1 ? "1er" : String(day)) \(rest)"
    }
}
