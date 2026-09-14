//
//  RootView.swift
//  ListingForge
//
//  Switches between the auth flow and the main app based on session state.
//

import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    var body: some View {
        switch appEnvironment.auth.state {
        case .loading:
            ProgressView()
                .task { appEnvironment.auth.restore() }
        case .signedOut:
            AuthView()
        case let .signedIn(user):
            if let cache = appEnvironment.accountCache, cache.userID == user.id {
                MainTabView()
                    .modelContainer(cache.container)
                    .id(user.id)
            } else {
                ContentUnavailableView {
                    Label("Couldn’t open your products", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(appEnvironment.cacheError ?? "Preparing your account…")
                } actions: {
                    Button("Try again") { appEnvironment.retryAccountCache() }
                    Button("Sign out") { appEnvironment.auth.signOut() }
                }
            }
        }
    }
}
