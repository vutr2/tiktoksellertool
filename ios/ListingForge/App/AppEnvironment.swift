//
//  AppEnvironment.swift
//  ListingForge
//
//  Root object graph. Injected via SwiftUI's Observation-based `.environment`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let api: APIClient
    let auth: AuthStore

    init() {
        let api = APIClient(baseURL: AppConfig.apiBaseURL)
        self.api = api
        self.auth = AuthStore(api: api)
    }
}
