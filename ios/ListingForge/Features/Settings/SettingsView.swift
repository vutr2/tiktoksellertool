//
//  SettingsView.swift
//  ListingForge
//
//  Account controls, including mandatory in-app account deletion (§5.3).
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var showDeleteConfirmation = false

    private var auth: AuthStore { appEnvironment.auth }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Permanently deletes your account and all associated data. This cannot be undone.")
                }
            }
            .navigationTitle("Settings")
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
                Text("This permanently deletes your data and cannot be undone.")
            }
        }
    }
}
