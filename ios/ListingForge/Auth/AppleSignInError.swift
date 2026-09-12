//
//  AppleSignInError.swift
//  ListingForge
//
//  Turns ASAuthorizationError into something a seller can act on.
//
//  The framework's own localizedDescription reads
//  "The operation couldn't be completed. (com.apple.AuthenticationServices.
//  AuthorizationError error 1000.)" — a developer string that should never
//  reach the UI.
//

import AuthenticationServices
import Foundation

enum AppleSignInError {

    /// The message to show, or nil when nothing should be shown because the
    /// seller dismissed the sheet themselves.
    static func message(for error: Error) -> String? {
        guard let authError = error as? ASAuthorizationError else {
            return error.localizedDescription
        }

        switch authError.code {
        case .canceled:
            return nil
        case .unknown:
            // Overwhelmingly this means no Apple Account is signed in — the
            // usual case on a fresh simulator.
            return "Sign in with Apple isn’t available. Open Settings and sign in to your Apple Account, then try again — or use email instead."
        case .invalidResponse:
            return "Apple returned an unexpected response. Please try again."
        case .notHandled:
            return "That sign-in request couldn’t be handled. Please try again."
        case .failed:
            return "Apple couldn’t verify your account. Please try again or use email instead."
        case .notInteractive:
            return "Sign in with Apple needs ListingForge to be open and in the foreground."
        default:
            return "Sign in with Apple didn’t work. Please try again or use email instead."
        }
    }
}
