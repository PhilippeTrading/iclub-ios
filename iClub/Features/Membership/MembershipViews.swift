//
//  MembershipViews.swift
//  iClub
//
//  Devenir adhérent depuis l'app : les formules du club, puis le paiement.
//
//  Trois façons de payer :
//    • carte ou Apple Pay, sur la page sécurisée Stripe ;
//    • prélèvement SEPA, sur la même page ;
//    • au secrétariat du club.
//  Les deux premières ne s'activent que lorsque le club a branché Stripe côté
//  serveur ; d'ici là, l'app propose de régler au club.
//

import AuthenticationServices
import SwiftUI

// MARK: - Formules

struct MembershipFormulasView: View {
    @Environment(AuthController.self) private var auth

    @State private var formulas: [MembershipFormula] = []
    @State private var isLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choisissez la formule qui vous correspond. Elle couvre la saison en cours.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)

                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                } else if !isLoaded {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 120, cornerRadius: Radius.card) }
                } else if formulas.isEmpty {
                    PhasePlaceholder(
                        systemImage: "person.text.rectangle",
                        title: "Aucune formule en ligne",
                        message: "Le club n'a pas encore publié ses formules d'adhésion. Renseignez-vous au secrétariat."
                    )
                }

                ForEach(formulas) { formula in
                    NavigationLink {
                        MembershipCheckoutView(formula: formula)
                    } label: {
                        FormulaCard(formula: formula)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Devenir adhérent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let clubId = auth.sessionProfile?.clubId else { return }
            do {
                formulas = try await MembershipService.formulas(clubId: clubId)
            } catch {
                errorMessage = "Les formules n'ont pas pu être chargées. Vérifiez votre connexion."
            }
            isLoaded = true
        }
    }
}

private struct FormulaCard: View {
    let formula: MembershipFormula

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formula.nom)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 8)
                    Text(Price.amount(formula.prix))
                        .font(.numeral(.title3))
                        .foregroundStyle(Brand.navy800)
                }
                if let detail = formula.detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Brand.textSecondary)
                }
                if let note = formula.note, !note.isEmpty {
                    Label(note, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Brand.textPrimary)
                }
                if let perks = formula.avantagesTexte, !perks.isEmpty {
                    Label(perks, systemImage: "star")
                        .font(.footnote)
                        .foregroundStyle(Brand.textPrimary)
                }
                HStack {
                    if formula.mensualisable {
                        BrandChip(title: "Paiement en plusieurs fois au club", tint: Brand.navy700)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }
}

// MARK: - Paiement

struct MembershipCheckoutView: View {
    let formula: MembershipFormula

    @Environment(AuthController.self) private var auth
    @Environment(\.webAuthenticationSession) private var webSession
    @Environment(\.openURL) private var openURL

    @State private var method: MembershipPaymentMethod = .carte
    @State private var desk: ClubDesk?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var outcome: Outcome?

    enum Outcome: Equatable {
        /// Carte ou Apple Pay : l'adhésion est créée par le serveur à la
        /// confirmation de Stripe, en quelques secondes.
        case paid
        /// SEPA : le prélèvement se confirme en quelques jours.
        case sepaPending
        /// Au club : demande transmise (ou simplement les informations).
        case atClub(recorded: Bool)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard

                if let outcome {
                    outcomeCard(outcome)
                } else {
                    methodPicker
                    if method == .club { deskCard }
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }
                    Text("L'adhésion se prend pour la saison en cours. Un reçu vous est remis dans « Reçus et factures » de votre profil.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Adhésion")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if outcome == nil {
                PrimaryActionButton(title: buttonTitle, systemImage: method.symbolName, isLoading: isWorking) {
                    proceed()
                }
                .disabled(isWorking)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .hidesMessageBubble()
        .task {
            if let clubId = auth.sessionProfile?.clubId {
                desk = await MembershipService.clubDesk(clubId: clubId)
            }
        }
    }

    private var buttonTitle: String {
        switch method {
        case .carte: "Payer \(Price.amount(formula.prix))"
        case .sepa: "Payer par prélèvement"
        case .club: "Je paierai au club"
        }
    }

    // MARK: - Récapitulatif

    private var summaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                ProfileCardHeader(title: "Votre formule")
                HStack(alignment: .firstTextBaseline) {
                    Text(formula.nom)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Text(Price.amount(formula.prix))
                        .font(.numeral(.title3))
                        .foregroundStyle(Brand.navy800)
                }
                if let detail = formula.detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Brand.textSecondary)
                }
                if let sports = formula.sportsLabel {
                    Text(sports).font(.footnote).foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    // MARK: - Moyen de paiement

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Moyen de paiement").metaLabelStyle()
            ForEach(MembershipPaymentMethod.allCases) { option in
                Button {
                    method = option
                    errorMessage = nil
                    Haptics.selection()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Brand.navy700)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: method == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(method == option ? Brand.navy700 : Brand.textSecondary)
                    }
                    .padding(14)
                    .background(Brand.surface, in: .rect(cornerRadius: Radius.chip, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(method == option ? Brand.navy700 : Brand.hairline, lineWidth: method == option ? 1.5 : 0.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(method == option ? [.isSelected] : [])
            }
        }
    }

    @ViewBuilder
    private var deskCard: some View {
        if let desk {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    ProfileCardHeader(title: "Au secrétariat")
                    if let address = desk.adresse { Label(address, systemImage: "mappin.and.ellipse").font(.footnote) }
                    if let methods = desk.paymentMethodsLabel { Label(methods, systemImage: "banknote").font(.footnote) }
                    if let phone = desk.telephone {
                        Button {
                            let digits = PhoneNumber.normalize(phone)
                            if let url = URL(string: "tel:\(digits)") { openURL(url) }
                        } label: {
                            Label(phone, systemImage: "phone.fill").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(Brand.navy700)
                    }
                }
                .foregroundStyle(Brand.textPrimary)
            }
        }
    }

    // MARK: - Résultat

    private func outcomeCard(_ outcome: Outcome) -> some View {
        SurfaceCard {
            VStack(spacing: 12) {
                Image(systemName: outcome == .paid ? "checkmark.circle.fill" : "hourglass.circle.fill")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(outcome == .paid ? Brand.success : Brand.navy700)
                Text(outcomeTitle(outcome))
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)
                    .multilineTextAlignment(.center)
                Text(outcomeMessage(outcome))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func outcomeTitle(_ outcome: Outcome) -> String {
        switch outcome {
        case .paid: "Paiement reçu"
        case .sepaPending: "Prélèvement enregistré"
        case .atClub: "À bientôt au club"
        }
    }

    private func outcomeMessage(_ outcome: Outcome) -> String {
        switch outcome {
        case .paid:
            "Votre adhésion « \(formula.nom) » s'active dans quelques instants. Votre reçu sera dans votre profil."
        case .sepaPending:
            "Votre adhésion s'activera à la confirmation du prélèvement par votre banque, sous quelques jours."
        case .atClub(let recorded):
            recorded
                ? "Le club a bien reçu votre demande. Réglez \(Price.amount(formula.prix)) au secrétariat : votre adhésion sera activée à réception."
                : "Présentez-vous au secrétariat pour régler \(Price.amount(formula.prix)) : le club activera votre adhésion à réception."
        }
    }

    // MARK: - Actions

    private func proceed() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                switch method {
                case .club:
                    let recorded = try await MembershipService.requestAtClub(formula: formula)
                    outcome = .atClub(recorded: recorded)
                    Haptics.success()
                case .carte, .sepa:
                    let url = try await MembershipService.startCheckout(formula: formula, method: method)
                    // Page Stripe dans une session web sécurisée : la carte et
                    // l'IBAN ne passent jamais par l'app.
                    let callback = try await webSession.authenticate(
                        using: url,
                        callbackURLScheme: MembershipService.callbackScheme,
                        preferredBrowserSession: .ephemeral
                    )
                    // Retour « iclub://adhesion/succes » ou « …/annule ».
                    guard callback.lastPathComponent == "succes" else {
                        return  // Paiement abandonné : on reste sur l'écran.
                    }
                    outcome = method == .sepa ? .sepaPending : .paid
                    Haptics.success()
                    await refreshMembership()
                }
            } catch ASWebAuthenticationSessionError.canceledLogin {
                // Page fermée par le membre : rien à signaler.
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    /// L'adhésion est créée par le serveur à la confirmation de Stripe, pas
    /// tout à fait instantanément : on relit le profil quelques fois.
    private func refreshMembership() async {
        for _ in 0..<5 {
            await auth.refreshSessionProfile()
            if auth.sessionProfile?.hasActiveMembership == true { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
