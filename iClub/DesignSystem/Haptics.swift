//
//  Haptics.swift
//  iClub
//
//  Retours haptiques légers sur les actions positives, retour plus sobre et
//  mat sur les actions destructives.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

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

    /// Échec d'une opération.
    static func failure() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Changement de segment, de date, de sport.
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Tap sur un élément flottant (bouton en verre, slot de partie).
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Action destructive confirmée (annulation d'une réservation) : sec, sans
    /// la tonalité positive d'un `success`.
    static func destructive() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}
