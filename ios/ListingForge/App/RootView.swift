//
//  RootView.swift
//  ListingForge
//
//  Switches between the auth flow and the main app based on session state.
//

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
        case .signedIn:
            MainTabView()
        }
    }
}
