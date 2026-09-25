//
//  AppLanguage.swift
//  ListingForge
//
//  The language the app speaks: its own interface, the messages the server
//  sends back, and the listing copy Claude writes. Chosen at sign-in and
//  changeable in Settings.
//

import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case en
    case vi

    var id: String { rawValue }

    /// Where the choice is stored. One key, read by the preference object on
    /// the main actor and by `APIClient` from whichever thread a request is on.
    static let storageKey = "listing-output-language"

    /// The `Accept-Language` value for this choice, so the server's messages
    /// come back in the same language as the interface.
    var httpTag: String {
        switch self {
        case .en: return "en"
        case .vi: return "vi-VN,vi;q=0.9,en;q=0.8"
        }
    }

    /// Each language names itself: someone who picked the wrong one cannot read
    /// a list written in the language they do not speak.
    var displayName: String {
        switch self {
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        }
    }

    /// A phone already set to Vietnamese starts on Vietnamese. Defaulting
    /// everyone to English would make the picker look broken to exactly the
    /// sellers the second language exists for.
    static func deviceDefault(locale: Locale = .current) -> AppLanguage {
        locale.language.languageCode?.identifier == "vi" ? .vi : .en
    }

    /// The stored choice, or the device's language until one is made.
    ///
    /// `APIClient` calls this on every request rather than being handed a value
    /// at init, because the seller can change the language in Settings
    /// mid-session. It is deliberately not main-actor isolated: `UserDefaults`
    /// is safe to read from any thread, so no shared mutable state is needed to
    /// carry the choice off the main actor.
    static func resolved(from defaults: UserDefaults = .standard) -> AppLanguage {
        if let stored = defaults.string(forKey: storageKey), let known = AppLanguage(rawValue: stored) {
            return known
        }
        return deviceDefault()
    }
}

/// Stored per device rather than per account, because the picker appears on the
/// sign-in screen — before there is an account to attach it to. It is a
/// preference, not a secret, so it does not belong in the Keychain next to
/// `AIConsent`.
@MainActor
@Observable
final class LanguagePreference {
    private(set) var language: AppLanguage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage.resolved(from: defaults)
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
    }
}
