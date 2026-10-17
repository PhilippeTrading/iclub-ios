//
//  ForgotPasswordView.swift
//  iClub
//
//  Flux standard Supabase : envoi d'un email de réinitialisation.
//

import SwiftUI

struct ForgotPasswordView: View {
    let prefilledEmail: String

    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSend = false

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if didSend {
                    sentState
                } else {
                    form
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Mot de passe oublié")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.3), value: didSend)
            .animation(.smooth(duration: 0.3), value: errorMessage)
        }
        .onAppear { email = prefilledEmail }
    }

    private var form: some View {
        VStack(spacing: 16) {
            Text("Indique ton adresse email : tu recevras un lien pour choisir un nouveau mot de passe.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 14) {
                    GlassFieldGroup {
                        AuthField(
                            kind: .email,
                            systemImage: "envelope",
                            placeholder: "Adresse email",
                            text: $email
                        )
                    }

                    if let errorMessage {
                        InlineMessage(kind: .error, message: errorMessage)
                    }

                    PrimaryActionButton(
                        title: "Envoyer le lien",
                        systemImage: "paperplane.fill",
                        isLoading: isSubmitting
                    ) {
                        submit()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private var sentState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Brand.success)
                .padding(.top, 12)

            Text("Lien envoyé")
                .font(.editorial(.title3))
                .foregroundStyle(Brand.navy800)

            Text("Si un compte existe pour \(email.lowercased()), un email vient de partir. Pense à regarder tes indésirables.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            SecondaryActionButton(title: "Terminé") { dismiss() }
                .padding(.top, 4)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await auth.sendPasswordReset(to: email)
                didSend = true
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.warning()
            }
            isSubmitting = false
        }
    }
}

#Preview {
    ForgotPasswordView(prefilledEmail: "camille@example.com")
        .environment(AuthController())
}
