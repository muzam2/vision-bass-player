import SwiftUI

extension View {
    /// visionOS 26 "Look to Scroll": scroll views scroll when the user looks at their edge.
    /// Opt-in per app (this modifier, inherited by every scroll view below it) and per user
    /// (Settings on the headset). No-op elsewhere.
    @ViewBuilder
    func lookToScroll() -> some View {
        #if os(visionOS)
        if #available(visionOS 26.0, *) {
            self.scrollInputBehavior(.enabled, for: .look)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
