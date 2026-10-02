import SwiftUI
import TipKit

// Liquid Glass on iOS 26, translucent material before that.

extension View {
    @ViewBuilder func glassCard(_ radius: CGFloat = 24) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Soft background in the logo's colours so the glass has something to refract; adapts to the theme.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [Color.orange.opacity(scheme == .dark ? 0.22 : 0.16),
                                    Color.purple.opacity(scheme == .dark ? 0.28 : 0.14),
                                    Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// First run: «tap a chat to open it on the Mac». Disappears for good after the first tap.
struct OpenChatTip: Tip {
    var title: Text { Text(String(localized: "Tap a chat to open it on the Mac")) }
    var message: Text? { Text(String(localized: "The mic button dictates a message into that chat.")) }
    var image: Image? { Image(systemName: "hand.tap") }
}
