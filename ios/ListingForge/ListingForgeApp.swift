//
//  ListingForgeApp.swift
//  ListingForge
//
//  App entry point. Builds the shared, server-authoritative environment and the
//  SwiftData cache used only for offline viewing (§9: the server always wins).
//

import SwiftUI
import SwiftData

@main
struct ListingForgeApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
        }
    }
}
