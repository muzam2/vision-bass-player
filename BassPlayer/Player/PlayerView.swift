import SwiftUI
import AVKit

/// Picks the backend for an item: FFmpeg (KSPlayer) by default, AVPlayer as fallback.
struct PlayerView: View {
    let item: MediaItem

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink

    var body: some View {
        Group {
            if let url = library.url(for: item) {
                switch library.backend {
                case .ffmpeg:
                    FFmpegPlayerView(item: item, url: url)
                case .avplayer:
                    AVPlayerBackendView(item: item, url: url)
                }
            } else {
                ContentUnavailableView("No stream URL", systemImage: "exclamationmark.triangle",
                                       description: Text("The server did not provide a playable file for this item."))
            }
        }
        .navigationTitle(item.title)
        #if os(visionOS)
        .toolbar {
            ToolbarItem(placement: .bottomOrnament) {
                ImmersiveScreenToggle()
            }
        }
        #endif
    }
}

/// AVPlayer backend (MP4/MOV, H.264/HEVC, AAC/AC‑3/E‑AC‑3; other files via server remux).
struct AVPlayerBackendView: View {
    let item: MediaItem
    let url: URL

    @EnvironmentObject private var bassLink: BassLink
    @StateObject private var controller: PlayerController

    init(item: MediaItem, url: URL) {
        self.item = item
        self.url = url
        _controller = StateObject(wrappedValue: PlayerController(bassLink: BassLinkHolder.shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: controller.player)
                .aspectRatio(16/9, contentMode: .fit)

            HStack(spacing: 16) {
                Text(item.title).font(.headline)
                Spacer()
                Label(controller.tapInstalled ? "Bass tap on" : "Bass tap off",
                      systemImage: controller.tapInstalled ? "waveform" : "waveform.slash")
                    .foregroundStyle(controller.tapInstalled ? .green : .secondary)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear {
            if bassLink.state == .off { bassLink.start() }
            controller.load(url: url)
        }
        .onDisappear { controller.stop() }
    }
}

/// Lets `PlayerView` reach the app-wide `BassLink` at `@StateObject` init time.
/// Set once in `BassPlayerApp`.
enum BassLinkHolder {
    static var shared: BassLink!
}
