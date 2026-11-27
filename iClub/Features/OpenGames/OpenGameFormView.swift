//
//  OpenGameFormView.swift
//  iClub
//
//  Réglages de la partie (format, niveau recherché, mixité, ambiance), puis
//  sa création : dernière étape du tunnel « Ouvrir une partie ».
//
//  Deux blocages sont évalués *avant* toute saisie et remplacent le formulaire
//  entier : classement non renseigné pour ce sport, et partie déjà en cours ce
//  jour-là. Laisser remplir un formulaire voué à l'échec serait une perte de
//  temps doublée d'une erreur incompréhensible à la fin.
//
//  Place dans l'application
//    Onglet « Parties », quatrième étape du tunnel (sport, créneau, terrain,
//    réglages ; les trois premières sont dans `OpenGameCreateFlow.swift`).
//    `OpenGamesView.formDestination` relit le terrain dans le catalogue avant
//    d'ouvrir cet écran, et lui passe le magasin des parties de l'onglet. La
//    création passe par `OpenGameService.create` : insertion dans
//    `reservations` (avec `est_partie_ouverte = true`), puis de l'hôte dans
//    `reservation_participants`. L'écran de succès est `OpenGameConfirmedView`.
//
//  Règles métier
//    - La partie s'ouvre toujours au nom du compte connecté
//      (`auth.sessionProfile`), jamais d'un enfant : la liste masque le bouton
//      « Ouvrir une partie » quand on agit pour un enfant.
//    - Valeurs proposées : double imposé au padel, simple ailleurs ; fourchette
//      d'un cran autour du classement de l'hôte ; partie mixte. Les mixités que
//      l'hôte ne pourrait pas lui-même rejoindre sont grisées.
//    - Le créneau est réservé dès la création, sans paiement (statut
//      `inclus`, montant nul, écrits par le service).
//    - Sous réserve de pluie : sur un terrain couvert, l'écran demande à la
//      base, par `RainReserveService.risk` (fonction SQL
//      `cours_exterieurs_concurrents`), si un cours ou un stage du même sport
//      se tient en extérieur au même moment. Si oui, l'avis
//      (`RainReserveNotice`) s'affiche au-dessus des réglages, et « Ouvrir la
//      partie » passe d'abord par une fenêtre de confirmation : titre « Ouvrir
//      la partie sous réserve de pluie ? », message `RainRisk.consequence`,
//      boutons « Oui, j'ouvre la partie » et « Non ». C'est la fenêtre du web
//      (`src/components/member/OpenGameTunnel.tsx`), avec les mêmes mots.
//      « Non » ne crée rien. L'app n'envoie jamais `sous_reserve_pluie` : le
//      déclencheur de la base le calcule à l'insertion, avec la même fonction.
//
//  Ce que la base revérifie
//    Créneau déjà pris à la même heure de début (index unique : fenêtre
//    « Créneau indisponible ») ; terrain fermé au groupe de l'hôte
//    (déclencheur `acces_terrain`, message de la base) ; seconde partie le
//    même jour (déclencheur `one_open_game_per_day`, à l'inscription de
//    l'hôte : le service rend alors « La partie n'a pas pu être ouverte »).
//    Le classement obligatoire n'est vérifié que par l'app.
//
//  Effets de bord
//    Écritures en base par `OpenGameService.create` ; relecture du magasin
//    des parties ; pile de navigation de l'onglet remplacée par l'écran de
//    succès. La demande de risque de pluie ne fait que lire.
//
//  Points d'attention
//    - Limite connue, partagée avec le web : la demande de risque de pluie
//      part à l'affichage, et le bouton « Ouvrir la partie » reste actif en
//      attendant sa réponse. Un appui avant la réponse crée la partie sans
//      avis ni fenêtre, alors que la base la marquera sous réserve de pluie.
//      Une erreur réseau, ou la fonction absente, vaut « aucun risque ».
//    - Attention : pendant la relecture du magasin qui suit la création, la
//      nouvelle partie compte déjà parmi celles du jour. D'après le code, le
//      bandeau « Déjà une partie ce jour-là » peut donc remplacer le formulaire
//      un instant, avant l'écran de succès.
//    - Si l'inscription de l'hôte échoue, le service supprime la réservation ;
//      la RLS réserve cette suppression à l'administration, si bien qu'un
//      adhérent garde une réservation sans joueur qui bloque le créneau
//      (défaut connu, `docs/defauts-connus.md` du web).
//
//  Fil d'exécution
//    Vue sur l'acteur principal (isolement par défaut du projet). La création
//    tourne dans une tâche qui en hérite ; préparation et demande de risque de
//    pluie partent des modificateurs `.task` de l'écran.
//

import SwiftUI

/// Formulaire d'ouverture d'une partie sur un terrain et un créneau choisis.
struct OpenGameFormView: View {
    /// Sport, jour et créneau choisis dans le tunnel, et l'identifiant du
    /// terrain.
    let route: OpenGameFormRoute
    /// Terrain choisi, relu dans le catalogue par la liste : identifiant et
    /// nom, durée de créneau et caractère couvert (pour le risque de pluie).
    let court: Court
    /// Magasin des parties de l'onglet, partagé avec la liste : il dit si
    /// l'hôte joue déjà ce jour-là, et il est relu après la création.
    let store: OpenGamesStore

    /// Session : le compte connecté, qui sera l'hôte.
    @Environment(AuthController.self) private var auth
    /// Navigation : pile de l'onglet « Parties » et onglet affiché.
    @Environment(AppRouter.self) private var router

    /// Format choisi (simple ou double) ; réglé par `prepare` à l'ouverture.
    @State private var format: GameFormat = .simple
    /// « Tous niveaux » : aucune fourchette n'est envoyée.
    @State private var allLevels = false
    /// Borne basse de la fourchette, valeur stockée de l'échelle (« 30/2 »,
    /// « 4.0 ») ; vide tant qu'aucune n'est proposée.
    @State private var minLevel = ""
    /// Borne haute de la fourchette, même format.
    @State private var maxLevel = ""
    /// Mixité choisie ; mixte à l'ouverture.
    @State private var mixite: Mixite = .mixte
    /// Ambiance choisie ; loisir par défaut.
    @State private var ambiance: Ambiance = .loisir

    /// Création en cours : bouton en attente et désactivé.
    @State private var isCreating = false
    /// Refus ou erreur de la création, affiché sous les réglages.
    @State private var errorMessage: String?
    /// Vrai quand le créneau vient d'être pris : ouvre la fenêtre « Créneau
    /// indisponible ».
    @State private var slotTaken = false
    /// Vrai une fois les valeurs initiales posées : un retour sur l'écran ne
    /// les réinitialise pas.
    @State private var hasPrepared = false
    /// Cours en extérieur qui pourrait reprendre ce terrain couvert s'il pleut,
    /// tel que la base l'a dit (`RainReserveService.risk`). `nil` : terrain
    /// extérieur, aucun cours à cette heure-là, réponse pas encore arrivée, ou
    /// erreur de lecture.
    @State private var rainRisk: RainRisk?
    /// Vrai pendant que la fenêtre « Ouvrir la partie sous réserve de pluie ? »
    /// est ouverte.
    @State private var asksRainConfirmation = false

    /// Le compte connecté, futur hôte. C'est toujours lui, jamais l'enfant
    /// au nom de qui l'on agirait (voir l'en-tête).
    private var profile: SessionProfile? { auth.sessionProfile }
    /// Sport de la partie.
    private var sport: Sport { route.sport }
    /// Échelle de classement du sport, du plus faible au plus fort ; vide en
    /// pickleball.
    private var scale: [String] { Ranking.scale(for: sport) }

    /// Récapitulatif, puis le bandeau de blocage ou le formulaire ; bouton
    /// de création en bas, absent quand un blocage s'affiche.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Rappel du créneau : date, heures, sport et terrain.
                recap

                // Un blocage remplace tout le formulaire (classement manquant,
                // ou déjà une partie ce jour-là).
                if let block = creationBlock {
                    blockNotice(block)
                } else {
                    // Avis « Sous réserve de pluie », en tête des réglages,
                    // quand la base a répondu qu'un cours extérieur pourrait
                    // reprendre le terrain.
                    if let rainRisk {
                        RainReserveNotice(risk: rainRisk)
                    }

                    formatSection
                    levelSection
                    mixitySection
                    ambianceSection

                    // Refus ou erreur de la dernière tentative de création.
                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }
                }

                // Espace libre en fin de défilement, sous la dernière section.
                Spacer(minLength: 96)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle("Ouvrir une partie")
        .navigationBarTitleDisplayMode(.inline)
        // Barre du bouton de création, fixée en bas ; absente quand un
        // blocage empêche d'ouvrir la partie.
        .safeAreaInset(edge: .bottom) {
            if creationBlock == nil { confirmBar }
        }
        // Le bouton du bas est l'action principale : la bulle ne doit pas le couvrir.
        .hidesMessageBubble()
        // Créneau pris entre-temps : retour à la liste des parties (racine de
        // l'onglet), d'où l'on relance le tunnel.
        .alert("Créneau indisponible", isPresented: $slotTaken) {
            Button("Choisir un autre créneau") {
                router.openGamesPath = NavigationPath()
            }
        } message: {
            Text(OpenGameError.slotAlreadyTaken.localizedDescription)
        }
        // Sous réserve de pluie : l'hôte l'accepte avant tout envoi. La
        // fenêtre ne s'ouvre qu'avec un risque connu ; son message est le
        // second paragraphe de l'avis, mot pour mot. « Non » referme la
        // fenêtre sans rien créer.
        .alert("Ouvrir la partie sous réserve de pluie ?", isPresented: $asksRainConfirmation, presenting: rainRisk) { _ in
            Button("Oui, j'ouvre la partie") { create() }
            Button("Non", role: .cancel) {}
        } message: { risk in
            Text(risk.consequence)
        }
        // Valeurs initiales, une seule fois (voir `hasPrepared`).
        .task { prepare() }
        // Risque de pluie, demandé à la base à chaque apparition de l'écran.
        // La clé (terrain, jour, heure de début) ne change pas tant que
        // l'écran est affiché : route et terrain sont fixes. Sur un terrain
        // extérieur, le service répond `nil` sans rien demander. La fin
        // envoyée à la fonction est le début plus la durée du terrain, soit
        // la fin du créneau que la création écrira (`slot.endMinutes`) :
        // `AvailabilityEngine` découpe les créneaux selon la durée de leur
        // terrain.
        .task(id: RainRiskKey(courtId: court.id, day: SupabaseDate.day(from: route.date), start: route.slot.startMinutes)) {
            rainRisk = await RainReserveService.risk(court: court, date: route.date, slot: route.slot)
        }
    }

    // MARK: - Préparation

    /// Valeurs initiales : format imposé au padel, fourchette centrée sur le
    /// classement de l'hôte, partie mixte.
    ///
    /// Ne tourne qu'une fois, et seulement si le compte connecté est connu :
    /// un retour sur l'écran (changement d'onglet, par exemple) garde les
    /// choix déjà faits.
    private func prepare() {
        guard !hasPrepared, let profile else { return }
        hasPrepared = true

        // Double au padel, simple ailleurs.
        format = GameFormat.preferred(for: sport)

        // Fourchette d'un cran de part et d'autre du classement de l'hôte,
        // bornée aux extrémités de l'échelle.
        if Ranking.hasScale(sport),
           let mine = Ranking.memberRanking(profile, sport: sport),
           let suggested = Ranking.suggestedRange(around: mine, sport: sport) {
            minLevel = suggested.min
            maxLevel = suggested.max
            allLevels = false
        } else {
            // Pickleball : aucun classement au club, donc toujours tous niveaux.
            // Même repli au tennis et au padel si le classement de l'hôte manque
            // (le formulaire est alors remplacé par le bandeau de blocage) ou
            // n'est pas sur l'échelle (les bornes restent vides).
            allLevels = true
        }

        mixite = .mixte
    }

    // MARK: - Blocages

    /// Blocage qui remplace le formulaire, ou `nil` si rien n'empêche d'ouvrir
    /// la partie : l'hôte figure déjà dans une partie ouverte ce jour-là
    /// (d'après les parties du magasin, du jour et à venir), ou son classement
    /// manque dans un sport qui en a. Recalculé à chaque affichage ; `nil`
    /// sans compte connecté.
    private var creationBlock: OpenGameEligibility.CreationBlock? {
        guard let profile else { return nil }
        return OpenGameEligibility.creationBlock(
            sport: sport,
            profile: profile,
            engagedSameDay: store.isEngaged(profileId: profile.id, on: route.date)
        )
    }

    /// Bandeau d'un blocage : titre, explication, et un bouton qui mène à la
    /// solution.
    ///
    /// - Parameter block: blocage à expliquer.
    /// - Returns: une carte dont le bouton referme le tunnel, puis affiche le
    ///   profil (classement à renseigner) ou la liste des parties (pour
    ///   quitter l'autre partie du jour).
    private func blockNotice(_ block: OpenGameEligibility.CreationBlock) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                // Titre du blocage, précédé d'un triangle d'avertissement.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Brand.warning)
                    Text(block.title)
                        .font(.editorial(.headline))
                        .foregroundStyle(Brand.textPrimary)
                }

                Text(block.message)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)

                // « Aller à mon profil » ou « Voir les parties ouvertes ».
                Button(block.actionTitle) {
                    // Le tunnel se referme d'abord, puis l'onglet voulu s'affiche.
                    router.openGamesPath = NavigationPath()
                    switch block {
                    case .missingRanking: router.selectedTab = .profile
                    case .alreadyEngagedSameDay: router.selectedTab = .openGames
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Récapitulatif

    /// Rappel du créneau choisi : date en toutes lettres, heures, sport et
    /// nom du terrain.
    private var recap: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(route.date.longFrenchDate)
                    .metaLabelStyle()

                Text(route.slot.label)
                    .font(.editorial(.title3))
                    .foregroundStyle(Brand.navy800)

                // Icône du sport et nom du terrain.
                HStack(spacing: 8) {
                    Image(systemName: sport.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sport.accent)
                    Text(court.nom)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Format

    /// Choix du format : simple ou double, chacun avec son nombre de joueurs ;
    /// au padel, simple mention du double, seul format possible.
    @ViewBuilder
    private var formatSection: some View {
        let options = GameFormat.options(for: sport)

        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .metaLabelStyle()

            if options.count == 1, let only = options.first {
                // Padel : toujours double. Une information, pas un choix.
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(sport.accent)
                    Text("\(only.displayName) · \(only.detail)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(sport.accent.opacity(0.10), in: .rect(cornerRadius: Radius.chip, style: .continuous))
            } else {
                // Tennis et pickleball : deux segments, « Simple » et « Double ».
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        segment(
                            title: option.displayName,
                            detail: option.detail,
                            isSelected: format == option
                        ) { format = option }
                    }
                }
            }
        }
    }

    // MARK: - Niveau

    /// Niveau recherché, pour les sports qui ont une échelle (tennis, padel) :
    /// interrupteur « Tous niveaux », sinon deux menus pour les bornes. Le
    /// classement de l'hôte est rappelé à droite du titre.
    @ViewBuilder
    private var levelSection: some View {
        if Ranking.hasScale(sport) {
            VStack(alignment: .leading, spacing: 8) {
                // Titre, et « Vous : 15/2 » quand le classement est connu.
                HStack {
                    Text("Niveau recherché")
                        .metaLabelStyle()
                    Spacer(minLength: 0)
                    if let mine = myRankingLabel {
                        Text("Vous : \(mine)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }

                Toggle(isOn: $allLevels) {
                    Text("Tous niveaux")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Brand.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(sport.accent)
                .padding(14)
                .surfaceCard(cornerRadius: Radius.inner)

                // Bornes de la fourchette, seulement hors « Tous niveaux ».
                if !allLevels {
                    HStack(spacing: 8) {
                        levelMenu(title: "Minimum", selection: $minLevel)
                        levelMenu(title: "Maximum", selection: $maxLevel)
                    }

                    // Fourchette inversée : expliquée ici, et bouton de
                    // création désactivé.
                    if isRangeInverted {
                        InlineMessage(
                            kind: .error,
                            message: "Le minimum doit être inférieur ou égal au maximum."
                        )
                    }
                }
            }
        }
    }

    /// Menu d'une borne : toutes les valeurs de l'échelle du sport, de la
    /// plus faible à la plus forte, affichées à la française (« 4,5 » au
    /// padel).
    ///
    /// - Parameters:
    ///   - title: « Minimum » ou « Maximum ».
    ///   - selection: borne liée, en valeur stockée.
    /// - Returns: le titre et le menu, sur la moitié de la largeur.
    private func levelMenu(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

            Menu {
                // Une entrée par valeur de l'échelle.
                ForEach(scale, id: \.self) { value in
                    Button(Ranking.display(value, sport: sport)) { selection.wrappedValue = value }
                }
            } label: {
                // Valeur choisie, avec les chevrons d'un menu déroulant.
                HStack(spacing: 6) {
                    Text(Ranking.display(selection.wrappedValue, sport: sport))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .surfaceCard(cornerRadius: Radius.chip)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Classement de l'hôte dans ce sport, tel qu'affiché (« 15/2 », « 4,5 ») ;
    /// `nil` s'il n'est pas renseigné.
    private var myRankingLabel: String? {
        guard let profile, let mine = Ranking.memberRanking(profile, sport: sport) else { return nil }
        return Ranking.display(mine, sport: sport)
    }

    /// Une fourchette inversée est refusée : elle n'admettrait personne.
    ///
    /// Les bornes se comparent par leur position sur l'échelle, pas par leur
    /// texte. Faux en « Tous niveaux », ou si une borne n'est pas sur
    /// l'échelle (vide, par exemple).
    ///
    /// Limite connue : si les bornes sont restées vides (classement de l'hôte
    /// hors de l'échelle), décocher « Tous niveaux » sans en choisir laisse
    /// envoyer la création avec deux bornes vides.
    private var isRangeInverted: Bool {
        guard !allLevels,
              let low = Ranking.index(of: minLevel, sport: sport),
              let high = Ranking.index(of: maxLevel, sport: sport)
        else { return false }
        return low > high
    }

    // MARK: - Mixité

    /// Choix de la mixité : trois segments, dont ceux que l'hôte ne pourrait
    /// pas rejoindre lui-même sont grisés, puis la phrase qui dit l'effet du
    /// choix.
    @ViewBuilder
    private var mixitySection: some View {
        // Sans compte connu, seule « Mixte » reste possible.
        let allowed = profile.map(OpenGameEligibility.allowedMixities) ?? [.mixte]

        VStack(alignment: .leading, spacing: 8) {
            Text("Mixité")
                .metaLabelStyle()

            HStack(spacing: 8) {
                ForEach(Mixite.allCases) { option in
                    let isAllowed = allowed.contains(option)
                    segment(
                        title: option.displayName,
                        detail: nil,
                        isSelected: mixite == option,
                        isEnabled: isAllowed
                    ) { mixite = option }
                }
            }

            // « Tout le monde peut rejoindre cette partie », ou la restriction.
            Text(mixite.effect)
                .font(.caption)
                .foregroundStyle(Brand.textSecondary)

            // L'hôte étant joueur, il ne peut pas ouvrir une partie dont il
            // serait lui-même exclu : sans sexe renseigné, seule « Mixte » est
            // possible, et l'on dit comment débloquer les autres.
            if profile?.sexe == nil {
                InlineMessage(kind: .info, message: OpenGameEligibility.missingSexeNotice)
            }
        }
    }

    // MARK: - Ambiance

    /// Choix de l'ambiance : « Loisir » (pour jouer sans enjeu) ou
    /// « Compétitif » (match sérieux, signalé par un badge sur la carte).
    private var ambianceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ambiance")
                .metaLabelStyle()

            HStack(spacing: 8) {
                ForEach(Ambiance.allCases) { option in
                    segment(
                        title: option.displayName,
                        detail: option.detail,
                        isSelected: ambiance == option
                    ) { ambiance = option }
                }
            }
        }
    }

    // MARK: - Segment réutilisable

    /// Bouton d'un choix exclusif (format, mixité, ambiance), à la couleur du
    /// sport : plein quand il est choisi, teinté sinon.
    ///
    /// Le texte blanc sur l'accent du sport est gardé en mode sombre (fiche
    /// D13 du web) ; au pickleball, le contraste est faible.
    ///
    /// - Parameters:
    ///   - title: libellé principal.
    ///   - detail: précision sous le libellé (« 2 joueurs »), `nil` pour aucune.
    ///   - isSelected: vrai pour l'option choisie.
    ///   - isEnabled: faux pour une option interdite : grisée et inactive.
    ///   - action: choix de l'option, suivi d'un retour haptique de sélection.
    /// - Returns: le segment, signalé « sélectionné » à VoiceOver quand il l'est.
    private func segment(
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 6)
            // Choisi : texte blanc sur la couleur du sport. Sinon : texte à la
            // couleur du sport sur un fond teinté à 12 %.
            .foregroundStyle(isSelected ? Color.white : sport.accent)
            .background {
                RoundedRectangle.squircle(Radius.chip)
                    .fill(isSelected ? sport.accent : sport.accent.opacity(0.12))
            }
            // Option interdite : estompée à 40 %.
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Création

    /// Barre du bas : « Ouvrir la partie · 2 joueurs » (ou 4), en attente
    /// pendant la création, désactivée pendant ce temps ou avec une fourchette
    /// inversée.
    ///
    /// Avec un risque de pluie connu, l'appui ouvre d'abord la fenêtre de
    /// confirmation ; sinon il crée directement. Le bouton reste actif en
    /// attendant la réponse sur la pluie (limite de l'en-tête, comme sur le
    /// web).
    private var confirmBar: some View {
        VStack(spacing: 0) {
            PrimaryActionButton(
                title: "Ouvrir la partie · \(format.capacity) joueurs",
                systemImage: "checkmark",
                isLoading: isCreating
            ) {
                // Sous réserve de pluie : confirmation d'abord, création au
                // « Oui, j'ouvre la partie ».
                if rainRisk != nil {
                    asksRainConfirmation = true
                } else {
                    create()
                }
            }
            .disabled(isCreating || isRangeInverted)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // Fond de barre système, translucide.
        .background(.bar)
    }

    /// Crée la partie au nom du compte connecté, puis affiche l'écran de
    /// succès.
    ///
    /// Effets : insertion de la réservation et de l'hôte
    /// (`OpenGameService.create`), retour haptique, relecture du magasin,
    /// remplacement de la pile de navigation de l'onglet. En cas d'échec :
    /// fenêtre « Créneau indisponible » pour un créneau pris entre-temps,
    /// sinon le message de l'erreur sous les réglages (refus de la base,
    /// créneau passé, hôte non enregistré, erreur réseau).
    private func create() {
        guard let profile else { return }
        isCreating = true
        errorMessage = nil

        // Aucune fourchette en pickleball, ni quand « tous niveaux » est actif.
        let sendsRange = !allLevels && Ranking.hasScale(sport)

        Task {
            do {
                // Réservation de la partie, puis inscription de l'hôte. Le
                // marqueur de pluie n'est pas envoyé : la base le pose.
                let gameId = try await OpenGameService.create(
                    clubId: profile.clubId,
                    court: court,
                    date: route.date,
                    slot: route.slot,
                    format: format,
                    niveauMin: sendsRange ? minLevel : nil,
                    niveauMax: sendsRange ? maxLevel : nil,
                    mixite: mixite,
                    ambiance: ambiance,
                    host: profile
                )

                Haptics.success()
                // La nouvelle partie entre dans le magasin, donc dans la liste
                // (et dans la règle d'une partie par jour).
                await store.reload()
                isCreating = false

                // Le tunnel se referme derrière l'écran de succès : la pile ne
                // contient plus que lui, et son retour mène à la liste.
                var path = NavigationPath()
                path.append(OpenGameConfirmation(
                    gameId: gameId,
                    courtName: court.nom,
                    sport: sport,
                    date: route.date,
                    slot: route.slot,
                    format: format,
                    levelLabel: sendsRange
                        ? Ranking.rangeLabel(min: minLevel, max: maxLevel, sport: sport)
                        : "Tous niveaux"
                ))
                router.openGamesPath = path

            } catch OpenGameError.slotAlreadyTaken {
                // Quelqu'un a pris ce créneau entre l'affichage et l'envoi.
                isCreating = false
                Haptics.failure()
                slotTaken = true
            } catch {
                // Autre refus ou erreur : son message, sous les réglages.
                isCreating = false
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
        }
    }
}
