import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Hosts `PlayerView` in its own scene: a window on visionOS, full screen on tvOS.
/// Autoplay swaps `current` to the next item in place.
struct PlayerScreen: View {
    @State private var current: MediaItem?
    @Environment(\.dismiss) private var dismiss
    #if os(visionOS)
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// visionOS keeps a closed window's view tree alive (and updating) after its scene has
    /// disconnected. Such a ghost must not start, swap or autoplay anything.
    @State private var scene: UIWindowScene?
    @State private var dead = false
    #endif

    init(item: MediaItem?) {
        _current = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            #if os(visionOS)
            if dead {
                Color.black
            } else if let item = current {
                PlayerView(item: item) { next in if !dead { current = next } }
                    .id(item.id)
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "play.slash",
                                       description: Text("Pick something from the library window."))
            }
            #else
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
            #endif
        }
        #if os(visionOS)
        .lookToScroll()
        .background(WindowSceneProbe { s in if let s { scene = s } })
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { n in
            if let s = n.object as? UIWindowScene, s === scene, !dead {
                dead = true
                DiagLog.log("player window scene disconnected; view tree is now inert", "player")
            }
        }
        .onAppear { immersive.reconcile(playback: library.playback, openWindow: openWindow) }
        .onChange(of: scenePhase) { _, p in if p == .active { immersive.reconcile(playback: library.playback, openWindow: openWindow) } }
        #endif
    }
}
