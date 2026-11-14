//
//  Haptics.swift
//  iClub
//
//  Rôle
//    Retours haptiques (vibrations du moteur Taptic de l'iPhone) de toute l'app,
//    réunis en six intentions : succès, avertissement, échec, sélection, tap et
//    action destructrice. Les vues appellent `Haptics.success()` et non les
//    générateurs UIKit, pour qu'une même intention vibre de la même façon
//    partout.
//
//  Principe
//    Retours haptiques légers sur les actions positives, retour plus sobre et
//    mat sur les actions destructives.
//
//  Points d'attention
//    - Rien ne vibre dans le simulateur : à éprouver sur un iPhone.
//    - Si l'utilisateur a désactivé les retours haptiques du système dans les
//      réglages de l'iPhone, rien ne vibre : iOS décide, et l'app n'en reçoit
//      aucun signal.
//    - Le code UIKit est entouré de `#if canImport(UIKit)` : le fichier se
//      compile aussi sur une plateforme sans UIKit, où les fonctions ne font
//      rien.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Point d'entrée unique des retours haptiques. Fonctions statiques, sans état.
/// Comme tout le code de l'app (réglage SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
/// du projet), elles s'exécutent sur le fil principal, celui qu'exigent les
/// générateurs UIKit.
enum Haptics {

    /// Réservation confirmée, partie rejointe, inscription, adhésion, compte
    /// créé : la petite vibration de confirmation.
    ///
    /// Le générateur est préparé juste avant : sans cela, le moteur haptique
    /// peut être en veille et la vibration arriver en retard, voire pas du
    /// tout. (Rien ne vibre dans le simulateur : à éprouver sur un iPhone.)
    static func success() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }

    /// Champ invalide, niveau hors plage, quota atteint.
    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// Échec d'une opération (erreur du serveur, envoi impossible).
    static func failure() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Changement de segment, de date, de sport, d'onglet.
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Tap sur un élément flottant (bouton en verre, slot de partie, bulle de
    /// messagerie) : impact léger.
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Action destructive confirmée (annulation d'une réservation, retrait d'un
    /// document ou d'un membre de la famille) : sec, sans la tonalité positive
    /// d'un `success`.
    static func destructive() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}
