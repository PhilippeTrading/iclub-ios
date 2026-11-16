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
//  Place dans l'application
//    `MembershipFormulasView` (« Devenir adhérent ») est poussé depuis la
//    carte « Votre adhésion » de l'accueil quand le membre n'a pas d'adhésion
//    active (jamais pour un enfant sélectionné : c'est le parent qui paie), et
//    depuis la carte d'adhésion du profil. Une formule ouvre
//    `MembershipCheckoutView` (« Adhésion »).
//
//  Données et services (`MembershipService`)
//    - Formules : table `membership_formulas` du club, `actif = true`, triées
//      par `ordre` ; lisibles par tous (politique RLS de catalogue public).
//    - Secrétariat : téléphone, adresse et moyens de paiement au comptoir
//      (table `clubs`).
//    - Carte et SEPA : fonction serveur Supabase `adhesion-paiement`, qui
//      rend l'adresse d'une page Stripe Checkout ; la page s'ouvre dans une
//      session web sécurisée et revient par `iclub://adhesion/succes` ou
//      `iclub://adhesion/annule`.
//    - Au club : fonction SQL `demander_adhesion`, qui enregistre la demande.
//    Contrat détaillé : docs/PAIEMENT_ADHESION.md.
//
//  Droits et sécurité
//    L'app ne fixe aucun prix et ne voit ni carte ni IBAN. Elle n'écrit jamais
//    dans `memberships` (interdit par la RLS au membre) : c'est le serveur
//    qui crée l'adhésion à la confirmation de Stripe, ou l'administration à
//    réception d'un règlement au club.
//
//  Points d'attention
//    - D'après le dépôt web, ni la fonction serveur `adhesion-paiement` ni la
//      fonction SQL `demander_adhesion` n'existent encore : en l'état, la
//      carte et le SEPA aboutissent au message « Le paiement en ligne n'est
//      pas encore activé », et « Au club » n'affiche que les informations du
//      secrétariat (demande non enregistrée).
//    - L'écran « Paiement reçu » se fonde sur la seule adresse de retour de
//      Stripe ; l'adhésion n'apparaît que lorsque le serveur l'a créée.
//

import AuthenticationServices
import SwiftUI

// MARK: - Formules

/// Écran « Devenir adhérent » : la liste des formules actives du club.
struct MembershipFormulasView: View {
    /// Session : club du compte connecté.
    @Environment(AuthController.self) private var auth

    /// Formules actives du club, dans l'ordre choisi par l'administration.
    @State private var formulas: [MembershipFormula] = []
    /// Vrai une fois la lecture terminée, réussie ou non.
    @State private var isLoaded = false
    /// Message d'échec de la lecture, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?

    /// Introduction, état du chargement, puis une carte par formule.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choisissez la formule qui vous correspond. Elle couvre la saison en cours.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)

                // Erreur, chargement (trois cartes fantômes) ou liste vide.
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

                // Une carte par formule, qui ouvre le paiement.
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
        // Lecture des formules à l'affichage ; pas de nouvelle tentative
        // automatique en cas d'échec.
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

/// Carte d'une formule : nom et prix, description, mention, avantages, et
/// possibilité de payer en plusieurs fois au club.
private struct FormulaCard: View {
    /// Formule présentée (`membership_formulas`).
    let formula: MembershipFormula

    /// Carte opaque, informations empilées, chevron à droite.
    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                // Nom et prix en euros (`membership_formulas.prix`).
                HStack(alignment: .firstTextBaseline) {
                    Text(formula.nom)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 8)
                    Text(Price.amount(formula.prix))
                        .font(.numeral(.title3))
                        .foregroundStyle(Brand.navy800)
                }
                // Textes facultatifs, affichés seulement s'ils sont remplis.
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
                    // `mensualisable` : le club accepte un paiement en
                    // plusieurs fois, au comptoir seulement.
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

/// Écran « Adhésion » : récapitulatif de la formule, choix du moyen de
/// paiement, puis issue (paiement reçu, prélèvement enregistré, ou rendez-vous
/// au club).
struct MembershipCheckoutView: View {
    /// Formule choisie.
    let formula: MembershipFormula

    /// Session : club du compte connecté, relecture du profil après paiement.
    @Environment(AuthController.self) private var auth
    /// Session web sécurisée du système, pour la page Stripe.
    @Environment(\.webAuthenticationSession) private var webSession
    /// Ouverture d'une adresse (appel du secrétariat).
    @Environment(\.openURL) private var openURL

    /// Moyen de paiement choisi ; carte par défaut.
    @State private var method: MembershipPaymentMethod = .carte
    /// Coordonnées du secrétariat, `nil` tant qu'elles ne sont pas lues ou si
    /// la lecture échoue.
    @State private var desk: ClubDesk?
    /// Vrai pendant la demande au serveur et la page Stripe.
    @State private var isWorking = false
    /// Message d'échec, `nil` s'il n'y en a pas.
    @State private var errorMessage: String?
    /// Issue du parcours ; tant qu'elle est `nil`, le formulaire est affiché.
    @State private var outcome: Outcome?

    /// Issue du parcours d'adhésion, qui remplace le formulaire.
    enum Outcome: Equatable {
        /// Carte ou Apple Pay : l'adhésion est créée par le serveur à la
        /// confirmation de Stripe, en quelques secondes.
        case paid
        /// SEPA : le prélèvement se confirme en quelques jours.
        case sepaPending
        /// Au club : demande transmise (ou simplement les informations).
        /// `recorded` est faux quand la base ne sait pas encore enregistrer la
        /// demande (`demander_adhesion` absente).
        case atClub(recorded: Bool)
    }

    /// Récapitulatif, puis le formulaire ou l'issue, et le bouton d'action
    /// fixé en bas.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard

                // Issue du parcours, ou formulaire de paiement.
                if let outcome {
                    outcomeCard(outcome)
                } else {
                    methodPicker
                    // Coordonnées du secrétariat pour un paiement au club.
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
        // Bouton d'action fixé en bas, tant que le parcours n'a pas abouti.
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
        // Le bouton du bas est l'action principale : la bulle ne doit pas le
        // couvrir.
        .hidesMessageBubble()
        // Coordonnées du secrétariat, lues dès l'affichage.
        .task {
            if let clubId = auth.sessionProfile?.clubId {
                desk = await MembershipService.clubDesk(clubId: clubId)
            }
        }
    }

    /// Libellé du bouton selon le moyen choisi : « Payer 180,00 € », « Payer
    /// par prélèvement » ou « Je paierai au club ».
    private var buttonTitle: String {
        switch method {
        case .carte: "Payer \(Price.amount(formula.prix))"
        case .sepa: "Payer par prélèvement"
        case .club: "Je paierai au club"
        }
    }

    // MARK: - Récapitulatif

    /// Carte « Votre formule » : nom, prix, description et sports inclus.
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
                // « Tennis, Padel », si la formule précise ses sports.
                if let sports = formula.sportsLabel {
                    Text(sports).font(.footnote).foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    // MARK: - Moyen de paiement

    /// Les trois moyens de paiement, présentés comme des boutons radio ;
    /// changer de moyen efface l'erreur affichée.
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
                    // Filet plus épais et bleu marine autour de l'option choisie.
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

    /// Carte « Au secrétariat » : adresse, moyens de paiement acceptés au
    /// comptoir et téléphone (un tap lance l'appel). Rien tant que les
    /// coordonnées ne sont pas lues.
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
                            // Le numéro est réduit à ses chiffres (et « + »)
                            // pour l'adresse `tel:`.
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

    /// Carte de fin de parcours : coche verte pour un paiement reçu, sablier
    /// sinon, avec un titre et une explication.
    ///
    /// - Parameter outcome: issue du parcours.
    /// - Returns: la carte.
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

    /// Titre de la carte de fin de parcours.
    ///
    /// - Parameter outcome: issue du parcours.
    /// - Returns: le titre.
    private func outcomeTitle(_ outcome: Outcome) -> String {
        switch outcome {
        case .paid: "Paiement reçu"
        case .sepaPending: "Prélèvement enregistré"
        case .atClub: "À bientôt au club"
        }
    }

    /// Explication de la carte de fin de parcours.
    ///
    /// - Parameter outcome: issue du parcours.
    /// - Returns: le texte, avec le nom de la formule ou son prix selon le cas.
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

    /// Lance le parcours du moyen choisi.
    ///
    /// - Au club : `demander_adhesion` enregistre la demande (si la fonction
    ///   existe), puis l'issue « À bientôt au club ».
    /// - Carte ou SEPA : demande d'une page Stripe à `adhesion-paiement`,
    ///   ouverture dans une session web éphémère (sans cookies partagés), puis,
    ///   au retour « succes », issue « Paiement reçu » ou « Prélèvement
    ///   enregistré » et relecture du profil.
    /// Une page fermée ou abandonnée ne signale rien ; toute autre erreur
    /// s'affiche au-dessus du bouton.
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
    /// Au plus cinq lectures, espacées de deux secondes ; on s'arrête dès que
    /// l'adhésion est active.
    private func refreshMembership() async {
        for _ in 0..<5 {
            await auth.refreshSessionProfile()
            if auth.sessionProfile?.hasActiveMembership == true { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
