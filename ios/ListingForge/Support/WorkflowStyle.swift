import SwiftUI

enum WorkflowStyle {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(red: 0.969, green: 0.965, blue: 0.957, alpha: 1)
    })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color.primary.opacity(0.12)
    static let green = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.32, green: 0.84, blue: 0.52, alpha: 1)
        : UIColor(red: 0.02, green: 0.48, blue: 0.21, alpha: 1) })
    static let amber = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 1)
        : UIColor(red: 0.65, green: 0.36, blue: 0.01, alpha: 1) })
    static let red = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)
        : UIColor(red: 0.80, green: 0.08, blue: 0.08, alpha: 1) })
}

extension View {
    func workflowCard(padding: CGFloat = 14, radius: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(WorkflowStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(WorkflowStyle.border, lineWidth: 0.8))
    }
}

struct WorkflowHeader: View {
    let title: String
    var step: String? = nil
    var backTitle = "Back"
    var isBusy = false
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text(backTitle).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }.disabled(isBusy)
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            Text(step ?? "").font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 22).frame(minHeight: 64)
        .background(WorkflowStyle.background)
    }
}

struct WorkflowPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
            .background(Color(white: 0.065).opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 13))
    }
}

struct WorkflowPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.11), in: Capsule())
    }
}
