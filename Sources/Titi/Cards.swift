import SwiftUI

/// A todo drawn as its own card: white (dark grey in dark mode), a hairline border and a faint shadow. The picked
/// ones take the accent, stronger while the keyboard is in the list. Both window views use it.
struct TodoCard: ViewModifier {
    let on: Bool
    let active: Bool
    var enabled = true

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(on ? (active ? 0.2 : 0.08) : 0)))
                        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                }
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(on ? Color.accentColor.opacity(active ? 0.7 : 0.35) : Color.primary.opacity(0.1), lineWidth: 1))
        } else {
            content
        }
    }
}

/// The frame around a window's list of cards: a faint grey panel with a hairline border.
struct ListFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

extension Row {
    /// Todos and closed lines are cards; headers, messages and the "Create" row are not.
    var isCard: Bool {
        switch self {
        case .task, .about, .closed: return true
        default: return false
        }
    }
}
