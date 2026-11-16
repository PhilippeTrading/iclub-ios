//
//  FormControls.swift
//  iClub
//
//  Rôle
//    Champs et boutons partagés par les formulaires. Les types clavier UIKit ne
//    sont jamais exposés dans les signatures : chaque champ déclare sa *nature*
//    (`AuthFieldKind`) et la vue applique les modificateurs adaptés (clavier,
//    majuscules, remplissage automatique d'iOS, masquage du mot de passe).
//
//  Place dans l'application
//    - `AuthField`, `GlassFieldGroup`, `FieldDivider`, `GlassFieldRow` : écrans
//      de connexion, de création de compte, de mot de passe oublié et de
//      complément de profil (Features/Auth), fiche d'un invité dans la
//      réservation (GuestFormSheet), informations personnelles du profil
//      (PersonalInfoSection).
//    - `PrimaryActionButton` : action principale de la plupart des écrans
//      (se connecter, réserver, s'inscrire, enregistrer...).
//    - `SecondaryActionButton` : action d'appoint (écrans d'authentification,
//      confirmation de réservation, écran « Compte en attente »).
//    - `InlineMessage` : erreurs, confirmations et informations affichées dans
//      le fil de l'écran, presque partout.
//
//  Points d'attention
//    - Le remplissage automatique d'iOS (trousseau iCloud, contacts) repose sur
//      les `textContentType` choisis ici : les changer change ce que l'iPhone
//      propose dans la barre au-dessus du clavier.
//    - Les boutons utilisent les styles Liquid Glass d'iOS 26 et plus
//      (`.glass`, `.glassProminent`), toujours disponibles avec la cible iOS 27
//      du projet.
//

import SwiftUI

// MARK: - Champs

/// Nature d'un champ de saisie. Elle décide du clavier, de la mise en
/// majuscules automatique, du type de contenu proposé par le remplissage
/// automatique d'iOS et du masquage éventuel du texte.
enum AuthFieldKind {
    /// Prénom : majuscule à chaque mot, remplissage par le prénom de la fiche
    /// de contact.
    case firstName
    /// Nom de famille : même traitement, avec le nom de la fiche de contact.
    case lastName
    /// Adresse électronique : clavier dédié, sans majuscule automatique.
    case email
    /// Numéro de téléphone : pavé numérique.
    case phone
    /// Mot de passe existant (connexion) : masqué, proposé par le trousseau.
    case currentPassword
    /// Nouveau mot de passe (création de compte, réinitialisation) : masqué,
    /// iOS peut proposer un mot de passe fort.
    case newPassword

    /// Vrai pour les deux natures de mot de passe : le champ est masqué et
    /// porte le bouton œil qui l'affiche en clair.
    var isSecure: Bool {
        self == .currentPassword || self == .newPassword
    }
}

/// Ligne de formulaire destinée à vivre dans un `GlassFieldGroup`.
///
/// Une icône à gauche (accentuée quand le champ a le focus), le champ, et pour
/// un mot de passe un bouton œil qui bascule entre texte masqué et texte clair.
/// Toute la ligne est cliquable : un tap hors du champ lui donne le focus.
struct AuthField: View {
    /// Nature du champ (voir `AuthFieldKind`).
    let kind: AuthFieldKind
    /// Symbole SF Symbols affiché à gauche.
    let systemImage: String
    /// Texte indicatif affiché tant que le champ est vide.
    let placeholder: String
    /// Valeur saisie, liée à l'état de l'écran appelant.
    @Binding var text: String
    /// Appelé quand le champ perd le focus. Permet de valider à la sortie
    /// plutôt qu'à chaque frappe, pour qu'un message d'erreur ne clignote pas
    /// pendant la saisie. Les écrans s'en servent pour le téléphone : l'erreur
    /// de format n'apparaît qu'une fois le champ quitté.
    var onEditingEnd: (() -> Void)?

    /// Mot de passe affiché en clair (bouton œil). Sans effet pour les autres
    /// natures de champ.
    @State private var isRevealed = false
    /// Le champ a le focus clavier.
    @FocusState private var isFocused: Bool

    /// Icône, champ et bouton œil éventuel, sur une ligne aux marges fixes.
    var body: some View {
        HStack(spacing: 12) {
            // Icône : couleur primaire pendant la saisie, secondaire sinon.
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .frame(width: 22)
                .animation(.smooth(duration: 0.2), value: isFocused)

            // Le champ propre à la nature (voir `field`), sans correction
            // automatique : elle abîmerait noms, adresses et mots de passe.
            field
                .focused($isFocused)
                .font(.body)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()

            // Mot de passe : bouton œil pour afficher ou masquer la saisie.
            if kind.isSecure {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isRevealed ? "Masquer le mot de passe" : "Afficher le mot de passe")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Toute la ligne, marges comprises, reçoit le tap.
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        // Perte du focus (le champ l'avait, il ne l'a plus) : on prévient
        // l'appelant.
        .onChange(of: isFocused) { wasFocused, isNowFocused in
            if wasFocused, !isNowFocused { onEditingEnd?() }
        }
    }

    /// Le champ de saisie lui-même, configuré selon `kind`.
    @ViewBuilder
    private var field: some View {
        switch kind {
        case .firstName:
            TextField(placeholder, text: $text)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)

        case .lastName:
            TextField(placeholder, text: $text)
                .textContentType(.familyName)
                .textInputAutocapitalization(.words)

        case .email:
            TextField(placeholder, text: $text)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)

        case .phone:
            TextField(placeholder, text: $text)
                // `.telephoneNumber` donne accès au remplissage automatique iOS.
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .textInputAutocapitalization(.never)

        // Mot de passe existant : un `TextField` quand il est affiché en
        // clair, un `SecureField` sinon ; les deux gardent le type `.password`
        // pour que le trousseau le reconnaisse.
        case .currentPassword:
            if isRevealed {
                TextField(placeholder, text: $text)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
            } else {
                SecureField(placeholder, text: $text)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
            }

        // Nouveau mot de passe : même bascule, avec le type `.newPassword`
        // qui permet à iOS de suggérer un mot de passe fort.
        case .newPassword:
            if isRevealed {
                TextField(placeholder, text: $text)
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
            } else {
                SecureField(placeholder, text: $text)
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
            }
        }
    }
}

/// Ligne générique d'un groupe de champs, pour héberger un contrôle qui n'est
/// pas une saisie texte (sélecteur de date, segment, menu…).
///
/// Même icône et mêmes marges horizontales qu'un `AuthField`, pour que les
/// lignes d'un groupe restent alignées ; marge verticale plus faible (10
/// points), les contrôles système ayant leur propre hauteur.
struct GlassFieldRow<Content: View>: View {
    /// Symbole SF Symbols affiché à gauche.
    let systemImage: String
    /// Contrôle hébergé, étiré sur toute la largeur restante.
    @ViewBuilder var content: Content

    /// Icône grise puis contrôle aligné à gauche.
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Séparateur entre deux champs d'un même groupe, aligné sur le texte.
struct FieldDivider: View {
    /// Trait système décalé de 50 points (16 de marge, 22 d'icône, 12
    /// d'espacement) pour commencer sous le texte des champs, à 40 % d'opacité.
    var body: some View {
        Divider()
            .padding(.leading, 50)
            .opacity(0.4)
    }
}

/// Groupe de champs posé sur un seul panneau de verre : un seul matériau pour
/// l'ensemble plutôt qu'un empilement de verres imbriqués.
struct GlassFieldGroup<Content: View>: View {
    /// Les lignes du groupe (`AuthField`, `GlassFieldRow`), séparées par des
    /// `FieldDivider`.
    @ViewBuilder var content: Content

    /// Lignes empilées sans espacement, sur un panneau de verre aux coins
    /// `Radius.control`.
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .glassPanel(cornerRadius: Radius.control)
    }
}

// MARK: - Boutons

/// Action principale d'un écran.
///
/// Bouton en verre teinté pleine largeur, police arrondie. Pendant une
/// opération (`isLoading`), un indicateur d'activité blanc remplace l'icône ;
/// le titre reste affiché. Le bouton ne se désactive pas de lui-même : c'est
/// à l'appelant de poser `.disabled()` pendant l'opération s'il veut bloquer
/// un second appui.
struct PrimaryActionButton: View {
    /// Texte du bouton.
    let title: String
    /// Symbole SF Symbols facultatif placé devant le texte.
    var systemImage: String?
    /// Vrai pendant l'opération lancée par le bouton : affiche l'indicateur
    /// d'activité à la place de l'icône.
    var isLoading = false
    /// Teinte du verre quand le bouton est actif : bleu marine par défaut,
    /// accent du sport sur le détail d'une activité, rouge d'erreur pour la
    /// suppression du compte.
    var tint: Color = Brand.navy700
    /// Action déclenchée à l'appui.
    let action: () -> Void

    /// Reflète le `.disabled()` posé par la vue parente : à l'état inactif on
    /// vide la teinte plutôt que de superposer une opacité, qui donnait un
    /// bouton gris boueux au lieu d'un verre discret.
    @Environment(\.isEnabled) private var isEnabled

    /// Le bouton, avec ses transitions douces entre états (chargement,
    /// activation).
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Chargement : indicateur d'activité ; sinon, l'icône éventuelle.
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(.headline, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        // Inactif : verre gris pâle (texte secondaire à 22 %) au lieu de la
        // teinte.
        .tint(isEnabled ? tint : Brand.textSecondary.opacity(0.22))
        .animation(.smooth(duration: 0.25), value: isLoading)
        .animation(.smooth(duration: 0.25), value: isEnabled)
    }
}

/// Action secondaire, en verre clair.
///
/// Même gabarit que `PrimaryActionButton` (pleine largeur, grande taille,
/// police arrondie), sans teinte ni état de chargement.
struct SecondaryActionButton: View {
    /// Texte du bouton.
    let title: String
    /// Symbole SF Symbols facultatif placé devant le texte.
    var systemImage: String?
    /// Action déclenchée à l'appui.
    let action: () -> Void

    /// Icône éventuelle et texte, dans un bouton de style verre clair.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(.headline, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

// MARK: - Messages en ligne

/// Message affiché dans le fil de l'écran (et non en alerte) : une icône et un
/// texte sur un fond teinté. Il apparaît en glissant depuis le haut et en
/// fondu quand l'appelant l'insère avec une animation.
struct InlineMessage: View {
    /// Nature du message, qui fixe sa couleur et son icône.
    enum Kind {
        /// Échec ou saisie refusée : rouge, triangle d'avertissement.
        case error
        /// Opération réussie : vert, coche.
        case success
        /// Information neutre : bleu marine, « i » cerclé.
        case info

        /// Couleur du texte, de l'icône et (à 12 %) du fond.
        var tint: Color {
            switch self {
            case .error: Brand.error
            case .success: Brand.success
            case .info: Brand.navy700
            }
        }

        /// Nom du symbole SF Symbols affiché devant le texte.
        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    /// Nature du message.
    let kind: Kind
    /// Texte affiché, déjà rédigé pour l'utilisateur.
    let message: String

    /// Icône alignée sur la première ligne du texte, fond teinté aux coins
    /// `Radius.chip`.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(kind.tint.opacity(0.12), in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
