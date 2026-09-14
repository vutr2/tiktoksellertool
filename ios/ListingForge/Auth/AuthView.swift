//
//  AuthView.swift
//  ListingForge
//
//  Sign in with Apple + email OTP. No third-party login (spec §5.6).
//

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false

    private var auth: AuthStore { appEnvironment.auth }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                appleButton
                dividerRow
                emailSection
                if let url = AppConfig.privacyPolicyURL {
                    Link("Privacy Policy", destination: url).font(.footnote)
                }
                if let message = auth.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("ListingForge")
            .disabled(auth.isBusy)
            .overlay { if auth.isBusy { ProgressView() } }
            .alert("Account deleted", isPresented: Binding(
                get: { auth.deletionNotice != nil },
                set: { if !$0 { auth.deletionNotice = nil } }
            )) {
                Button("OK") { auth.deletionNotice = nil }
            } message: { Text(auth.deletionNotice ?? "") }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Marketplace-ready listings from one photo.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
    }

    private var dividerRow: some View {
        HStack {
            line
            Text("or").font(.footnote).foregroundStyle(.secondary)
            line
        }
    }

    private var line: some View {
        Rectangle().frame(height: 1).foregroundStyle(.quaternary)
    }

    @ViewBuilder private var emailSection: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            if codeSent {
                TextField("6-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Verify & continue") {
                    Task { await auth.verifyEmailCode(email: email, code: code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count < 4)
            } else {
                Button("Continue with email") {
                    Task { if await auth.requestEmailCode(email) { codeSent = true } }
                }
                .buttonStyle(.bordered)
                .disabled(!email.contains("@"))
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                auth.errorMessage = "Apple sign-in did not return a token."
                return
            }
            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let formatter = PersonNameComponentsFormatter()
            let fullName = credential.fullName.map { formatter.string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            Task {
                await auth.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    email: credential.email,
                    fullName: fullName
                )
            }
        case let .failure(error):
            // nil for a user-cancelled sheet, which also clears any stale error.
            auth.errorMessage = AppleSignInError.message(for: error)
        }
    }
}
