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

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([CachedProduct.self, CachedAsset.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
        }
        .modelContainer(sharedModelContainer)
    }
}
