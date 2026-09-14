//
//  SettingsView.swift
//  ListingForge
//
//  Account controls, including mandatory in-app account deletion (§5.3).
//

import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var showingPlans = false
    @State private var showDeleteConfirmation = false

    private var auth: AuthStore { appEnvironment.auth }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plans and credits") {
                    Button("View plans and credits") { showingPlans = true }
                    Button("Restore Purchases") { Task { await appEnvironment.billing.restore() } }
                        .disabled(appEnvironment.billing.isBusy)
                    if let message = appEnvironment.billing.message { Text(message).font(.footnote) }
                }
                Section("Account") {
                    if case let .signedIn(user) = auth.state {
                        LabeledContent("Email", value: user.email ?? "—")
                    }
                    Button("Sign Out") { auth.signOut() }
                }

                Section {
                    Button("Delete Account", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } footer: {
                    Text("Deletes your account and product content. Purchase records needed for refunds may be retained. Deleting your account does not cancel an Apple subscription.")
                }

                if auth.needsAppleDeletionAuthorization {
                    Section("Disconnect Sign in with Apple") {
                        Text("Confirm your Apple account so we can disconnect it while deleting your ListingForge account.")
                        SignInWithAppleButton(.continue) { _ in } onCompletion: { result in
                            handleDeletionAuthorization(result)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 50)
                        Button("Delete account and disconnect Apple manually", role: .destructive) {
                            Task { await auth.deleteAccount(skipAppleRevocation: true) }
                        }
                    }
                }

                Section("Privacy and support") {
                    if let url = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: url) }
                    if let url = AppConfig.termsURL { Link("Terms of Use", destination: url) }
                    if let url = AppConfig.supportURL { Link("Contact support", destination: url) }
                    if appEnvironment.aiConsent.isGranted {
                        Button("Withdraw AI data-sharing permission") { appEnvironment.aiConsent.revoke() }
                        Text("Stops future AI requests until you allow sharing again. It does not delete content already generated.")
                            .font(.footnote)
                    }
                    Link("Manage Apple subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                }

                if let error = auth.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPlans) { PaywallView() }
            .disabled(auth.isBusy)
            .confirmationDialog(
                "Delete your account?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task { await auth.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your products will be deleted. This cannot be undone. Cancel any Apple subscription separately in Manage Apple subscriptions.")
            }
        }
    }

    private func handleDeletionAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
                auth.errorMessage = "Apple did not return authorization. Try again, or delete your account and disconnect Apple manually."
                return
            }
            Task { await auth.deleteAccount(identityToken: token, authorizationCode: code) }
        case .failure(let error):
            auth.errorMessage = AppleSignInError.message(for: error)
        }
    }
}
