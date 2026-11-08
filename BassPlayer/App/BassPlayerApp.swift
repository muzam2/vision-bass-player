import SwiftUI
import AVFoundation

@main
struct BassPlayerApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var jellyfin: JellyfinClient
    @StateObject private var plex: PlexClient
    @StateObject private var bassLink: BassLink
    #if os(visionOS)
    @StateObject private var immersive = ImmersiveScreenModel()
    @State private var immersionStyle: ImmersionStyle = .mixed
    #endif

    init() {
        let link = BassLink()
        BassLinkHolder.shared = link
        _bassLink = StateObject(wrappedValue: link)
        let jf = JellyfinClient()
        let px = PlexClient()
        _jellyfin = StateObject(wrappedValue: jf)
        _plex = StateObject(wrappedValue: px)
        _library = StateObject(wrappedValue: LibraryStore(jellyfin: jf, plex: px))

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
            ContentView()
                .environmentObject(library)
                .environmentObject(jellyfin)
                .environmentObject(plex)
                .environmentObject(bassLink)
                .environmentObject(immersive)
                .onChange(of: immersive.darkRoom, initial: true) { _, dark in
                    immersionStyle = dark ? .full : .mixed
                }
        }
        .defaultSize(width: 1100, height: 700)

        ImmersiveSpace(id: ImmersiveScreenSpace.id) {
            ImmersiveScreenView()
                .environmentObject(immersive)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
        #else
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(jellyfin)
                .environmentObject(plex)
                .environmentObject(bassLink)
        }
        #endif
    }
}
