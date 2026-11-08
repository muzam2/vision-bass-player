import SwiftUI
import AVFoundation

@main
struct BassPlayerApp: App {
    @StateObject private var jellyfin = JellyfinClient()
    @StateObject private var bassLink: BassLink

    init() {
        let link = BassLink()
        BassLinkHolder.shared = link
        _bassLink = StateObject(wrappedValue: link)

        // Movie playback category; the built-in audio pods or AirPods carry the full mix,
        // the sub gets the low-frequency stream over BLE from BassLink.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(jellyfin)
                .environmentObject(bassLink)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
