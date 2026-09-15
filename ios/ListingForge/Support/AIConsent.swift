import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AIConsent {
    private(set) var isGranted = false
    private let keychain = KeychainStore()
    private var key: String?
    // Increment if the recipient or the data shared changes.
    private let version = Data("anthropic-photo-and-product-text-v1".utf8)

    func useAccount(_ userID: String?) {
        key = userID.map { "ai-consent-\($0)" }
        isGranted = key.map { keychain.data(for: $0) == version } ?? false
    }

    func grant() {
        guard let key else { return }
        keychain.set(version, for: key)
        isGranted = true
    }

    func revoke() {
        if let key { keychain.delete(key) }
        isGranted = false
    }
}

struct AIConsentView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    var onAllow: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Use AI to create your listing?").font(.title.bold())
                    Text("Listing Force sends your product cutout photos, product details and visible label text to Anthropic, which processes them to generate listing text and ad scripts.")
                    Text("Background removal happens on your device. The original camera frame is not sent. Avoid including personal or sensitive information in your product photos and descriptions.")
                    Text("You can decline and keep your product without generating a listing. You can withdraw permission for future requests in Settings.")
                    if let url = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: url) }
                    Button("Allow and continue") {
                        appEnvironment.aiConsent.grant()
                        dismiss()
                        onAllow()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not now") { dismiss() }.buttonStyle(.bordered)
                }.padding()
            }
            .navigationTitle("AI data sharing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
