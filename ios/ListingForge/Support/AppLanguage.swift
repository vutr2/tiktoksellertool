//
//  AppLanguage.swift
//  ListingForge
//
//  The language the seller's listings are written in, chosen at sign-in and
//  changeable in Settings.
//

import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case en
    case vi

    var id: String { rawValue }

    /// Each language names itself: someone who picked the wrong one cannot read
    /// a list written in the language they do not speak.
    var displayName: String {
        switch self {
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        }
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
    private static let key = "listing-output-language"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A phone already set to Vietnamese starts on Vietnamese. Defaulting to
        // English would make the picker look broken to exactly the sellers the
        // second language exists for.
        if let stored = defaults.string(forKey: Self.key), let known = AppLanguage(rawValue: stored) {
            language = known
        } else {
            language = Self.deviceDefault()
        }
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        defaults.set(language.rawValue, forKey: Self.key)
    }

    static func deviceDefault(locale: Locale = .current) -> AppLanguage {
        locale.language.languageCode?.identifier == "vi" ? .vi : .en
    }
}
