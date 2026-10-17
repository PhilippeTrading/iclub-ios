//
//  FormControls.swift
//  iClub
//
//  Champs et boutons partagés par les formulaires. Les types clavier UIKit ne
//  sont jamais exposés dans les signatures : chaque champ déclare sa *nature*
//  (`AuthFieldKind`) et la vue applique les modificateurs adaptés.
//

import SwiftUI

// MARK: - Champs

enum AuthFieldKind {
    case firstName
    case lastName
    case email
    case phone
    case currentPassword
    case newPassword

    var isSecure: Bool {
        self == .currentPassword || self == .newPassword
    }
}

/// Ligne de formulaire destinée à vivre dans un `GlassFieldGroup`.
struct AuthField: View {
    let kind: AuthFieldKind
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    /// Appelé quand le champ perd le focus. Permet de valider à la sortie
    /// plutôt qu'à chaque frappe, pour qu'un message d'erreur ne clignote pas
    /// pendant la saisie.
    var onEditingEnd: (() -> Void)?

    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .frame(width: 22)
                .animation(.smooth(duration: 0.2), value: isFocused)

            field
                .focused($isFocused)
                .font(.body)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()

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
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .onChange(of: isFocused) { wasFocused, isNowFocused in
            if wasFocused, !isNowFocused { onEditingEnd?() }
        }
    }

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
struct GlassFieldRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: Content

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
    var body: some View {
        Divider()
            .padding(.leading, 50)
            .opacity(0.4)
    }
}

/// Groupe de champs posé sur un seul panneau de verre : un seul matériau pour
/// l'ensemble plutôt qu'un empilement de verres imbriqués.
struct GlassFieldGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .glassPanel(cornerRadius: Radius.control)
    }
}

// MARK: - Boutons

/// Action principale d'un écran.
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var tint: Color = Brand.navy700
    let action: () -> Void

    /// Reflète le `.disabled()` posé par la vue parente : à l'état inactif on
    /// vide la teinte plutôt que de superposer une opacité, qui donnait un
    /// bouton gris boueux au lieu d'un verre discret.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
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
        .tint(isEnabled ? tint : Brand.textSecondary.opacity(0.22))
        .animation(.smooth(duration: 0.25), value: isLoading)
        .animation(.smooth(duration: 0.25), value: isEnabled)
    }
}

/// Action secondaire, en verre clair.
struct SecondaryActionButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

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

struct InlineMessage: View {
    enum Kind {
        case error
        case success
        case info

        var tint: Color {
            switch self {
            case .error: Brand.error
            case .success: Brand.success
            case .info: Brand.navy700
            }
        }

        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    let kind: Kind
    let message: String

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
