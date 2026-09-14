import Foundation
import Observation

struct CaptureDraft: Codable {
    var id = UUID()
    var cutouts: [ProductCutout] = []
    var name = ""
    var category = ""
    var keyFeatures = ""
    var savedProduct: ProductDTO?
    /// Once the server may have seen the draft, its content is immutable on retry.
    var uploadStarted = false
}

@MainActor
@Observable
final class CaptureDraftStore {
    var draft: CaptureDraft { didSet { persist() } }
    private(set) var errorMessage: String?
    private let file: URL?
    private var isInvalidated = false

    init(directory: URL? = nil) {
        file = directory?.appendingPathComponent("capture-draft.json")
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(CaptureDraft.self, from: data) {
            draft = saved
        } else { draft = CaptureDraft() }
    }

    func invalidate() { isInvalidated = true }
    func reset() { draft = CaptureDraft() }

    private func persist() {
        guard !isInvalidated, let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: file,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            errorMessage = nil
        } catch { errorMessage = "Your draft could not be saved on this device. Keep the app open until the upload finishes." }
    }
}
