import SwiftUI

/// Hosts `PlayerView` in its own scene: a window on visionOS, full screen on tvOS.
/// Autoplay swaps `current` to the next item in place.
struct PlayerScreen: View {
    @State private var current: MediaItem?
    @Environment(\.dismiss) private var dismiss

    init(item: MediaItem?) {
        _current = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            if let item = current {
                PlayerView(item: item) { next in current = next }
                    .id(item.id)
                    #if os(tvOS)
                    .onExitCommand { dismiss() }
                    #endif
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "play.slash",
                                       description: Text("Pick something from the library window."))
            }
        }
    }
}
