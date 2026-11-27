//
//  RainReserve.swift
//  iClub
//
//  Réserver en salle sous réserve de pluie (règle du web, 30 octobre 2026).
//
//  Un terrain couvert réservé pendant qu'un cours se tient en extérieur, sur le
//  même sport, peut être repris par ce cours s'il pleut. La base décide de
//  tout : `cours_exterieurs_concurrents` dit s'il y a un tel cours, et la base
//  marque elle-même la réservation (`sous_reserve_pluie`) à l'insertion.
//  L'app ne fait que prévenir avant de réserver, avec les mots du web
//  (`src/lib/pluie.ts`, `AvisPluie.tsx`).
//
//  Ce fichier fournit la ligne rendue par la fonction SQL
//  (`OutdoorCourseRow`), le risque réduit à ce que l'avis affiche, avec ses
//  textes et ses formats (`RainRisk`), l'appel à la base
//  (`RainReserveService`), l'encadré d'avis (`RainReserveNotice`) et la clé
//  qui relance la demande quand le créneau change (`RainRiskKey`).
//
//  Place dans l'application
//    - Récapitulatif d'une réservation (`BookingSummaryView`) et formulaire
//      d'ouverture d'une partie (`OpenGameFormView`) : demande du risque à
//      l'affichage, avis sous le récapitulatif ou en tête du formulaire, puis
//      fenêtre de confirmation avant l'envoi, dont le message est
//      `RainRisk.consequence`.
//    - La carte d'une partie ouverte (`OpenGameCard`) n'utilise pas ce
//      fichier : elle lit le marqueur déjà posé par la base
//      (`reservations.sous_reserve_pluie`, voir `OpenGame.isRainReserve`).
//    Équivalents du web : `useRisquePluie` et `AvisPluie`
//    (`src/components/club/AvisPluie.tsx`), textes et formats de
//    `src/lib/pluie.ts`. Fonction SQL et déclencheur de la migration
//    `20261030120000_reservation_sous_reserve_pluie.sql` d'`iclub-web`.
//
//  Règles métier (portées par la base)
//    - `cours_exterieurs_concurrents` rend les séances de cours et de stages
//      (types individuel, duo, collectif et stage ; pas les événements), non
//      annulés, dont une séance prévue sur un terrain extérieur du même sport
//      que le terrain visé chevauche le créneau (bornes de fin exclues : une
//      séance qui commence pile à la fin du créneau ne compte pas). Rien si le
//      terrain visé n'est pas couvert. Tri par heure de début, puis par nom.
//    - Le déclencheur `sous_reserve_pluie` (fonction
//      `marquer_sous_reserve_pluie`) lit la même fonction à la création de
//      toute réservation confirmée, du web comme de l'app, et pose le
//      marqueur lui-même : ce que l'app enverrait serait ignoré. L'avis et le
//      marquage réel suivent donc la même règle.
//    - L'adhérent est fixé au plus tard `delai_minutes` avant son créneau
//      (`clubs.repli_pluie_delai_minutes`, entre 0 et 2 880 minutes, 60 par
//      défaut, réglable au back-office). Passé ce délai, sa réservation est
//      ferme.
//    - S'il pleut, le club passe le cours en salle depuis le planning du
//      back-office : les réservations sous réserve de pluie du terrain
//      couvert choisi, encore dans le délai, sont annulées
//      (`statut = 'annulee'`, motif « Pluie : ... ») et leurs joueurs
//      prévenus par courriel et par un message du club dans la messagerie de
//      l'app (notification par la fonction `push-message`).
//      Rien à coder ici : « Mes réservations » montre la réservation annulée
//      comme les autres.
//
//  Droits et sécurité
//    La fonction SQL n'est exécutable que par un utilisateur connecté, et ne
//    répond que pour un terrain d'un club dont l'appelant est membre
//    (`current_club_ids`). Elle ne fait que lire (`security definer` côté
//    base, pour lire activités et séances). Aucune clé de service dans l'app.
//
//  Effets de bord
//    Une lecture (appel RPC) à chaque affichage des deux écrans et à chaque
//    changement de terrain, de jour ou d'heure, seulement pour un terrain
//    couvert. Aucune écriture.
//
//  Points d'attention
//    - Les textes sont ceux du web, mot pour mot, avec une différence de
//      forme : les espaces des heures et des durées sont insécables ici
//      (U+00A0), ordinaires sur le web. Le tiret demi-cadratin entre les deux
//      heures du cours vient aussi du web ; c'est un texte affiché, laissé
//      tel quel.
//    - Limite connue, la même que sur le web : la réponse arrive après
//      l'affichage. Tant qu'elle n'est pas là, les écrans n'ont pas d'avis
//      et envoient sans fenêtre de confirmation, alors que la base marquera
//      la réservation. Une erreur de l'appel vaut « aucun risque ».
//    - Limite connue de la base : le marqueur n'est calculé qu'à la création.
//      Déplacer ensuite la réservation, ou créer plus tard un cours extérieur
//      au même moment, ne le recalcule pas.
//
//  Fil d'exécution
//    La ligne SQL et les paramètres sont isolés de l'acteur principal
//    (`nonisolated`, `Sendable`) : ils sont encodés et décodés en arrière-plan.
//    `RainRisk` est une valeur `Sendable`. Le service est appelé depuis les
//    vues, sur l'acteur principal ; l'appel réseau suspend sans bloquer.
//

import Foundation
import Supabase
import SwiftUI

// MARK: - Modèle

/// Une ligne rendue par la fonction SQL `cours_exterieurs_concurrents` : une
/// séance de cours ou de stage, en extérieur, qui chevauche le créneau visé.
nonisolated struct OutdoorCourseRow: Decodable, Sendable {
    /// Séance concernée (`activite_seances.id`). Décodée, mais ni l'app ni le
    /// web ne s'en servent.
    let seanceId: UUID
    /// Nom du cours ou du stage (`activites.nom`).
    let activiteNom: String
    /// Début de la séance, heure locale du club, au format de la base
    /// (« 09:00:00 »).
    let heureDebut: String
    /// Fin de la séance, même format.
    let heureFin: String
    /// Nom du terrain extérieur où se tient la séance (`courts.nom`).
    let courtNom: String
    /// Délai du club en minutes (`clubs.repli_pluie_delai_minutes`). Non nul
    /// en base ; optionnel ici par prudence, `nil` vaut le délai par défaut.
    let delaiMinutes: Int?

    /// Colonnes rendues par la fonction SQL.
    enum CodingKeys: String, CodingKey {
        case seanceId = "seance_id"
        case activiteNom = "activite_nom"
        case heureDebut = "heure_debut"
        case heureFin = "heure_fin"
        case courtNom = "court_nom"
        case delaiMinutes = "delai_minutes"
    }
}

/// Le cours en extérieur qui pourrait reprendre le terrain, réduit à ce que
/// l'avis affiche. Heures en minutes depuis minuit.
/// Équivalent du type `RisquePluie` du web, plus le début du créneau réservé.
struct RainRisk: Equatable, Sendable {
    /// Nom du premier cours ou stage concerné (le plus tôt, puis par nom).
    let courseName: String
    /// Nom du terrain extérieur où il se tient.
    let courtName: String
    /// Début de sa séance, en minutes depuis minuit (0 si l'heure est
    /// illisible).
    let start: Int
    /// Fin de sa séance, en minutes depuis minuit (0 si l'heure est
    /// illisible).
    let end: Int
    /// Délai de décision du club, en minutes avant le créneau de l'adhérent.
    let delayMinutes: Int
    /// Autres cours en extérieur à la même heure.
    /// (0 quand un seul cours est concerné.)
    let others: Int
    /// Début du créneau réservé : l'heure limite se compte à partir de lui.
    /// En minutes depuis minuit, jour du créneau.
    let slotStart: Int

    /// Le délai du club tant qu'il n'est pas renseigné.
    /// 60 minutes, comme la valeur par défaut de la colonne en base et la
    /// constante `DELAI_PLUIE_DEFAUT` du web.
    static let defaultDelay = 60

    // MARK: Textes (mot pour mot le web)

    /// Premier paragraphe de l'avis : « À cette heure-là, le cours », son nom
    /// entre guillemets, puis entre parenthèses son terrain et ses heures, et
    /// « se tient en extérieur. ». Quand plusieurs cours sont concernés, le
    /// premier est nommé et les autres comptés après la parenthèse (« et 1
    /// autre », « et 2 autres »). Phrase construite comme dans `AvisPluie`.
    var situation: String {
        // « et 1 autre », « et 2 autres », ou rien pour un seul cours.
        let more = others > 0 ? " et \(others) autre\(others > 1 ? "s" : "")" : ""
        return "À cette heure-là, le cours « \(courseName) » (\(courtName), \(Self.hour(start)) – \(Self.hour(end)))\(more) se tient en extérieur."
    }

    /// Le second paragraphe de l'avis, repris tel quel dans la confirmation.
    /// Il annonce l'annulation s'il pleut, l'heure limite où l'adhérent sera
    /// prévenu (par courriel et dans l'application), le délai du club, et le
    /// caractère ferme de la réservation passé ce délai. Même phrase que
    /// `textePluieAdherent` du web.
    var consequence: String {
        "S'il pleut, le cours « \(courseName) » passera en salle et votre réservation sera annulée. "
            + "Vous serez prévenu par courriel et dans l'application au plus tard \(Self.deadline(slotStart: slotStart, delay: delayMinutes)), "
            + "\(Self.delay(delayMinutes)) avant votre créneau. Passé ce délai, votre réservation est ferme."
    }

    // MARK: Formats

    /// « 9 h », « 9 h 30 ». Espace insécable : l'heure ne se coupe pas.
    /// L'heure pile s'écrit sans minutes, les minutes sur deux chiffres
    /// (« 9 h 05 »), comme `heureFr` du web. Différent de `TimeSlot.clock`,
    /// qui écrit toujours les minutes (« 09 h 00 »).
    ///
    /// - Parameter minutes: minutes depuis minuit (ou une durée, pour
    ///   `delay`).
    /// - Returns: l'heure en toutes lettres.
    static func hour(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h\u{00A0}\(String(format: "%02d", m))"
    }

    /// « 30 min », « 1 h », « 1 h 30 », « 24 h ».
    /// En minutes sous une heure, sinon en heures et minutes, comme `delaiFr`
    /// du web.
    ///
    /// - Parameter minutes: durée en minutes.
    /// - Returns: la durée en toutes lettres.
    static func delay(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)\u{00A0}min" : hour(minutes)
    }

    /// « à 9 h », ou « la veille à 23 h 30 » quand la limite tombe avant minuit.
    /// Au-delà d'un jour : « 2 jours avant, à 9 h ». Même calcul que
    /// `limitePluieFr` du web.
    ///
    /// - Parameters:
    ///   - slotStart: début du créneau de l'adhérent, en minutes depuis minuit.
    ///   - delay: délai du club, en minutes.
    /// - Returns: le moment limite, prêt à suivre « au plus tard ».
    static func deadline(slotStart: Int, delay: Int) -> String {
        // Limite en minutes depuis le minuit du jour du créneau ; négative si
        // elle tombe un jour précédent.
        let limit = slotStart - delay
        if limit >= 0 { return "à \(hour(limit))" }
        // Nombre de jours à remonter (1 440 minutes par jour, arrondi au jour
        // supérieur), puis l'heure dans ce jour-là.
        let days = Int((Double(-limit) / 1440).rounded(.up))
        let time = hour(limit + days * 1440)
        return days == 1 ? "la veille à \(time)" : "\(days) jours avant, à \(time)"
    }
}

// MARK: - Service

/// Lecture du risque de pluie d'un créneau, auprès de la base.
enum RainReserveService {

    /// Paramètres de `cours_exterieurs_concurrents`. Les noms des propriétés
    /// sont ceux des paramètres SQL : l'encodage synthétisé les écrit tels
    /// quels.
    private nonisolated struct Params: Encodable, Sendable {
        /// Terrain visé (`courts.id`).
        let p_court_id: UUID
        /// Jour du créneau, « AAAA-MM-JJ ».
        let p_date: String
        /// Début du créneau, « HH:MM ».
        let p_heure_debut: String
        /// Fin du créneau, « HH:MM ».
        let p_heure_fin: String
    }

    /// Le risque de pluie pour ce créneau, ou `nil` : terrain extérieur, aucun
    /// cours à cette heure-là, réseau coupé ou fonction pas encore déployée.
    /// Dans tous ces cas la réservation reste possible, sans avis.
    /// (Une tâche annulée, parce que l'écran a disparu, rend aussi `nil`.)
    ///
    /// - Parameters:
    ///   - court: terrain choisi ; seul un terrain couvert est examiné.
    ///   - date: jour du créneau, écrit « AAAA-MM-JJ » dans le fuseau de
    ///     l'appareil, comme à l'insertion de la réservation : la demande et
    ///     le déclencheur voient le même jour.
    ///   - slot: créneau visé ; son début compte, sa fin suit la durée du
    ///     terrain.
    /// - Returns: le premier cours concerné, le nombre des autres et le délai
    ///   du club ; `nil` sinon.
    static func risk(court: Court, date: Date, slot: TimeSlot) async -> RainRisk? {
        // Un terrain extérieur ne peut pas être repris : aucune demande.
        guard court.couvert else { return nil }
        // La fin suit la durée du terrain, comme la réservation qui sera créée.
        // (Elle vaut `slot.endMinutes` : `AvailabilityEngine` découpe les
        // créneaux selon la durée de leur terrain.)
        let end = slot.startMinutes + court.dureeCreneauMinutes
        let rows: [OutdoorCourseRow]
        do {
            // Lecture seule, sous la session du membre ; les lignes arrivent
            // triées par la base (heure de début, puis nom).
            rows = try await Supa.client
                .rpc("cours_exterieurs_concurrents", params: Params(
                    p_court_id: court.id,
                    p_date: SupabaseDate.day(from: date),
                    p_heure_debut: clock(slot.startMinutes),
                    p_heure_fin: clock(end)
                ))
                .execute()
                .value
        } catch {
            // Fonction absente, réseau, refus ou annulation : pas d'avis, comme
            // sur le web.
            return nil
        }
        // Aucun cours extérieur à cette heure-là : rien à annoncer.
        guard let first = rows.first else { return nil }
        // Le premier cours est nommé, les autres seulement comptés.
        return RainRisk(
            courseName: first.activiteNom,
            courtName: first.courtNom,
            start: PostgresTime.minutes(from: first.heureDebut) ?? 0,
            end: PostgresTime.minutes(from: first.heureFin) ?? 0,
            delayMinutes: first.delaiMinutes ?? RainRisk.defaultDelay,
            others: rows.count - 1,
            slotStart: slot.startMinutes
        )
    }

    /// « 10:00 ».
    /// Format accepté par une colonne ou un paramètre `time` de Postgres. Un
    /// créneau qui finit à minuit donne « 24:00 », que Postgres accepte aussi.
    ///
    /// - Parameter minutes: minutes depuis minuit.
    /// - Returns: l'heure sur deux chiffres, puis les minutes sur deux chiffres.
    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - Avis

/// L'encadré bleu affiché dans le récapitulatif, avant de réserver.
/// Aussi en tête du formulaire d'ouverture d'une partie. Équivalent de
/// `AvisPluie` du web : parapluie, titre « Sous réserve de pluie », puis les
/// deux paragraphes de `RainRisk`. Aucun texte blanc écrit en dur : les
/// couleurs suivent le mode clair ou sombre.
struct RainReserveNotice: View {
    /// Le cours concerné et le délai du club, tels que rendus par
    /// `RainReserveService.risk`.
    let risk: RainRisk

    /// L'encadré : icône à gauche, textes à droite, fond et bordure bleu
    /// marine très légers.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Parapluie, aligné sur la première ligne du titre.
            Image(systemName: "umbrella.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Brand.navy700)
                .frame(width: 22)

            // Titre, puis la situation et la conséquence, en entier : les
            // textes passent à la ligne au lieu d'être tronqués.
            VStack(alignment: .leading, spacing: 6) {
                Text("Sous réserve de pluie")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.navy800)
                Text(risk.situation)
                Text(risk.consequence)
            }
            .font(.footnote)
            .foregroundStyle(Brand.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fond à 8 % et bordure à 18 % du bleu marine : un avis d'information,
        // pas une erreur.
        .background(Brand.navy700.opacity(0.08), in: .rect(cornerRadius: Radius.inner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Brand.navy700.opacity(0.18))
        }
        // VoiceOver lit l'encadré d'un seul tenant : titre, puis paragraphes.
        .accessibilityElement(children: .combine)
    }
}

/// Clé de relecture : terrain, jour et heure. Si l'un change, on redemande.
/// Sert d'identifiant à `.task(id:)` dans les deux écrans. La fin du créneau
/// n'y figure pas : elle suit la durée du terrain, donc son identifiant.
struct RainRiskKey: Hashable {
    /// Terrain visé, `nil` tant que le brouillon n'en a pas.
    let courtId: UUID?
    /// Jour du créneau, « AAAA-MM-JJ » (`SupabaseDate.day`).
    let day: String
    /// Début du créneau, en minutes depuis minuit.
    let start: Int
}
