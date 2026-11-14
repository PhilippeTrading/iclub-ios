//
//  ProfileCards.swift
//  iClub
//
//  Rôle
//    Cartes de l'onglet Profil alignées sur le web : adhésion, famille, reçus et
//    factures, autres espaces. Une carte qui n'a rien à dire se replie sur une
//    ligne, avec son action s'il y en a une.
//
//  Contenu du fichier
//    - ProfileCardHeader et CollapsedProfileCard : briques communes ; l'en-tête
//      sert aussi aux fiches d'élève (Coach), à la fiche d'un membre
//      (Messaging) et aux écrans d'adhésion (Membership) ;
//    - MembershipBadge et MembershipSection : l'adhésion active, lue dans le
//      profil de session (table `memberships`, ligne `a_jour` la plus récente) ;
//      sans adhésion, lien « Adhérer » vers les formules (MembershipFormulasView) ;
//    - ReceiptsSection et ReceiptsListView : reçus, factures et avoirs
//      (`documents_comptables`), téléchargés en PDF depuis le site du club ;
//    - OtherSpacesRow : liens vers le back-office et l'espace entraîneur du
//      web, ouverts dans Safari ;
//    - `Date.frenchDayMonthYear` : « 1er septembre 2026 ».
//
//  Argent
//    Montants en euros (colonnes `numeric`, avec centimes), formatés par
//    `Price.amount` en français ; le montant d'un document comptable est son
//    montant TTC.
//

import QuickLook
import SwiftUI

// MARK: - Carte repliable

/// En-tête de carte commun : titre en petites capitales, action à droite.
struct ProfileCardHeader<Action: View>: View {
    /// Titre, affiché en capitales discrètes.
    let title: String
    /// Action facultative à droite (bouton « Ajouter »...).
    @ViewBuilder var action: Action

    /// Titre à gauche, action à droite.
    var body: some View {
        HStack {
            Text(title).metaLabelStyle()
            Spacer(minLength: 8)
            action
        }
    }
}

/// Variante sans action, pour écrire simplement `ProfileCardHeader(title:)`.
extension ProfileCardHeader where Action == EmptyView {
    /// En-tête sans action.
    /// - Parameter title: titre de la carte.
    init(title: String) {
        self.title = title
        self.action = EmptyView()
    }
}

/// Une carte qui n'a qu'une ligne à dire.
struct CollapsedProfileCard<Action: View>: View {
    /// Titre, en capitales discrètes.
    let title: String
    /// Phrase d'état (« Aucun document pour l'instant. »...).
    let message: String
    /// Action facultative à droite.
    @ViewBuilder var action: Action

    /// Titre et phrase à gauche, action à droite, dans une carte compacte.
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

/// Variante sans action, pour écrire `CollapsedProfileCard(title:message:)`.
extension CollapsedProfileCard where Action == EmptyView {
    /// Carte repliée sans action.
    /// - Parameters:
    ///   - title: titre de la carte.
    ///   - message: phrase d'état.
    init(title: String, message: String) {
        self.title = title
        self.message = message
        self.action = EmptyView()
    }
}

// MARK: - Badge d'adhésion (en-tête)

/// Pastille de la carte d'identité : adhésion à jour (avec sa date de fin) ou
/// aucune adhésion active.
struct MembershipBadge: View {
    /// Le compte connecté.
    let profile: SessionProfile

    /// Pastille verte avec la date de fin, ou grise.
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

/// Carte « Adhésion » : formule, montant et période de l'adhésion active, ou
/// invitation à adhérer.
struct MembershipSection: View {
    /// Le compte connecté.
    let profile: SessionProfile

    /// La carte détaillée, ou la carte repliée avec « Adhérer ».
    var body: some View {
        if let details = profile.activeMembershipDetails, let period = profile.activeMembershipPeriod {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    ProfileCardHeader(title: "Adhésion")
                    // Formule et montant (en euros).
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
            // Pas d'adhésion active (ou formule et période inconnues) : lien
            // vers les formules proposées en ligne.
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
    /// Documents comptables du membre, du plus récent au plus ancien.
    let receipts: [AccountingDocument]
    /// Sous-domaine du club, nécessaire au téléchargement.
    let clubSlug: String?

    /// Carte repliée sans document, sinon la ligne de résumé.
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
    ///
    /// Le premier document de la liste est le plus récent (tri par date
    /// d'émission décroissante).
    private var summary: String {
        let count = receipts.count == 1 ? "1 document" : "\(receipts.count) documents"
        guard let last = receipts.first?.emisLe else { return count }
        return "\(count) · le dernier le \(last.shortFrenchDate)"
    }
}

/// Tous les reçus, factures et avoirs du membre, du plus récent au plus ancien.
///
/// « Télécharger » demande le PDF au site du club
/// (`https://<sous-domaine>.iclubapp.fr/api/documents/<id>`, avec le jeton de
/// la session), l'écrit dans un fichier temporaire et l'ouvre en aperçu
/// QuickLook, d'où il se partage. La route web ne sert que les documents du
/// membre connecté.
struct ReceiptsListView: View {
    /// Documents comptables du membre.
    let receipts: [AccountingDocument]
    /// Sous-domaine du club ; `nil` : téléchargement impossible (boutons
    /// grisés).
    let clubSlug: String?

    /// Fichier PDF à afficher en aperçu ; le poser ouvre QuickLook.
    @State private var previewURL: URL?
    /// Document en cours de téléchargement (un seul à la fois).
    @State private var downloadingId: UUID?
    /// Message affiché en haut si le téléchargement échoue.
    @State private var errorMessage: String?

    /// Message éventuel, puis une carte listant tous les documents.
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Échec du téléchargement : présenté comme une information
                // (le document peut être demandé au club).
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

    /// Ligne d'un document : icône du type, libellé, « Type numéro · date ·
    /// mode de paiement », bouton « Télécharger », et montant TTC à droite.
    /// - Parameter receipt: le document.
    /// - Returns: la ligne.
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

                // Indicateur sur la ligne en cours ; tous les boutons sont
                // grisés pendant un téléchargement ou sans sous-domaine.
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

            // Montant TTC en euros, chiffres à chasse fixe pour l'alignement.
            Text(Price.amount(receipt.montantTtc))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Brand.textPrimary)
        }
    }

    /// Télécharge le PDF puis l'ouvre en aperçu ; en cas d'échec, message en
    /// haut de l'écran.
    /// - Parameter receipt: le document.
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
///
/// Liens vers `https://<sous-domaine>.iclubapp.fr/admin` et `/coach` ; le web
/// redemandera la connexion si Safari n'a pas de session. Rien ne s'affiche
/// pour un simple membre, ni sans sous-domaine.
struct OtherSpacesRow: View {
    /// Le compte connecté (droits d'administrateur et d'entraîneur).
    let profile: SessionProfile
    /// Sous-domaine du club.
    let clubSlug: String?

    /// Ouverture des liens dans Safari.
    @Environment(\.openURL) private var openURL

    /// Intitulé et un bouton par espace auquel le compte a droit.
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

    /// Bouton qui ouvre une page du site du club.
    /// - Parameters:
    ///   - title: texte du bouton.
    ///   - systemImage: symbole SF Symbols.
    ///   - path: chemin de la page (« admin », « coach »).
    ///   - slug: sous-domaine du club.
    /// - Returns: le bouton.
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

/// Date longue à la française, utilisée par les cartes d'adhésion, la fiche
/// d'un élève et d'autres écrans.
extension Date {
    /// « 1er septembre 2026 », « 31 août 2027 ».
    ///
    /// Le premier du mois s'écrit « 1er », comme en français écrit ; mois en
    /// toutes lettres, en français, dans le fuseau de l'appareil.
    var frenchDayMonthYear: String {
        let day = Calendar.current.component(.day, from: self)
        let rest = formatted(Date.FormatStyle(date: .omitted, time: .omitted).month(.wide).year().locale(AppLocale.french))
        return "\(day == 1 ? "1er" : String(day)) \(rest)"
    }
}
