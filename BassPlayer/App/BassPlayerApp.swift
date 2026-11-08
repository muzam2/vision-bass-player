import SwiftUI
import AVFoundation

@main
struct BassPlayerApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var jellyfin: JellyfinClient
    @StateObject private var plex: PlexClient
    @StateObject private var youtube: YouTubeClient
    @StateObject private var nas: NASClient
    @StateObject private var bassLink: BassLink
    #if os(visionOS)
    @StateObject private var immersive = ImmersiveScreenModel()
    @State private var immersionStyle: ImmersionStyle = .mixed
    #endif

    init() {
        // UI tests start from a clean slate (no saved servers, shares, recents or positions).
        if ProcessInfo.processInfo.environment["BASSPLAYER_UITEST"] == "1", let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        let link = BassLink()
        BassLinkHolder.shared = link
        _bassLink = StateObject(wrappedValue: link)
        let jf = JellyfinClient()
        let px = PlexClient()
        let yt = YouTubeClient()
        let ns = NASClient()
        let lib = LibraryStore(jellyfin: jf, plex: px, youtube: yt, nas: ns)
        _jellyfin = StateObject(wrappedValue: jf)
        _plex = StateObject(wrappedValue: px)
        _youtube = StateObject(wrappedValue: yt)
        _nas = StateObject(wrappedValue: ns)
        _library = StateObject(wrappedValue: lib)

        if DemoData.isEnabled {
            DemoData.apply(library: lib, jellyfin: jf, plex: px, youtube: yt)
        }

        FFmpegConfig.apply()

        // Movie playback category; the audio pods / AirPods carry the full mix,
        // the sub gets the low-frequency stream over BLE from BassLink.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    var body: some Scene {
        #if os(visionOS)
        WindowGroup {
            RootView()
                .modifier(AppEnvironment(library: library, jellyfin: jellyfin, plex: plex, youtube: youtube, nas: nas, bassLink: bassLink))
                .environmentObject(immersive)
                .onChange(of: immersive.darkRoom, initial: true) { _, dark in
                    immersionStyle = dark ? .full : .mixed
                }
        }
        .defaultSize(width: 1280, height: 820)

        // The player lives in its own window so the library stays usable beside it.
        WindowGroup(id: PlayerWindow.id, for: MediaItem.self) { $item in
            PlayerScreen(item: item)
                .modifier(AppEnvironment(library: library, jellyfin: jellyfin, plex: plex, youtube: youtube, nas: nas, bassLink: bassLink))
                .environmentObject(immersive)
        }
        .defaultSize(width: 1600, height: 900)
        // Never restore the player at launch: if a file crashes the player, restoration would
        // reopen the same file and crash again before the user can do anything.
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: ImmersiveScreenSpace.id) {
            ImmersiveScreenView()
                .modifier(AppEnvironment(library: library, jellyfin: jellyfin, plex: plex, youtube: youtube, nas: nas, bassLink: bassLink))
                .environmentObject(immersive)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
        #else
        WindowGroup {
            RootView()
                .modifier(AppEnvironment(library: library, jellyfin: jellyfin, plex: plex, youtube: youtube, nas: nas, bassLink: bassLink))
        }
        #endif
    }
}

/// Injects every shared model once, for both windows.
private struct AppEnvironment: ViewModifier {
    let library: LibraryStore
    let jellyfin: JellyfinClient
    let plex: PlexClient
    let youtube: YouTubeClient
    let nas: NASClient
    let bassLink: BassLink

    func body(content: Content) -> some View {
        content
            .environmentObject(library)
            .environmentObject(jellyfin)
            .environmentObject(plex)
            .environmentObject(youtube)
            .environmentObject(nas)
            .environmentObject(bassLink)
    }
}
