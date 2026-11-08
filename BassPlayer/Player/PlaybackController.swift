import Foundation
import SwiftUI
import Combine
import KSPlayer

/// Owns the one running playback: KSPlayer's coordinator (player layer, subtitle model, time
/// model) and the `FFmpegSession` (bass pipeline, progress, cinema-screen frame sink).
///
/// It lives on `LibraryStore`, not inside the player window, so the window can be dismissed
/// while the cinema screen shows the film and reopened afterwards without restarting anything.
@MainActor
final class PlaybackController: ObservableObject {
    let coordinator = KSVideoPlayer.Coordinator()
    @Published private(set) var session: FFmpegSession?
    @Published private(set) var item: MediaItem?
    @Published private(set) var url: URL?
    /// Mirror of the player layer's state, published (the coordinator's own is not).
    @Published private(set) var state: KSPlayerState = .initialized
    /// True while the player window has been dismissed in favour of the cinema screen; the
    /// player view's disappearance must not end playback then.
    var detachedForImmersive = false
    /// Set by the cinema's Stop button: the space closes, the window reopens, then ends playback
    /// and closes itself (so the user lands back on the library instead of in an empty void).
    var stopAfterCinema = false
    private var sessionSink: AnyCancellable?

    var isActive: Bool { item != nil }

    init() {
        coordinator.keepsPlayerWhenViewGoesAway = true
        coordinator.onStateChanged = { [weak self] layer, state in
            Task { @MainActor in self?.handle(state: state, layer: layer) }
        }
    }

    /// Start (or keep) playback of `item`. Called whenever a player view appears; the same item
    /// re-appearing after the window was reopened just gets the running session back.
    @discardableResult
    func begin(item: MediaItem, url: URL, library: LibraryStore, leadMs: Int) -> FFmpegSession {
        if let session, self.item?.id == item.id {
            DiagLog.log("resume view for \(item.title) (state \(state))", "playback")
            return session
        }
        session?.stop()
        let s = FFmpegSession(bassLink: BassLinkHolder.shared)
        s.configure(for: item)
        session = s
        sessionSink = s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.item = item
        self.url = url
        state = .initialized
        s.start(coordinator: coordinator, leadMs: leadMs, item: item, library: library)
        DiagLog.log("begin \(item.source.rawValue) · \(item.title)", "playback")
        return s
    }

    /// Stop playback and release the player.
    func end() {
        guard item != nil else { return }
        DiagLog.log("end \(item?.title ?? "")", "playback")
        session?.stop()
        coordinator.playerLayer?.pause()
        coordinator.playerLayer = nil
        sessionSink = nil
        session = nil
        item = nil
        url = nil
        state = .initialized
        detachedForImmersive = false
    }

    func togglePlayPause() {
        if state.isPlaying { coordinator.playerLayer?.pause() } else { coordinator.playerLayer?.play() }
    }

    private func handle(state: KSPlayerState, layer: KSPlayerLayer) {
        self.state = state
        DiagLog.log("state \(state)", "playback")
        if state == .readyToPlay {
            let a = layer.player.tracks(mediaType: .audio).map { "\($0.trackID):\($0.name)" }
            let s = layer.player.tracks(mediaType: .subtitle).map { "\($0.trackID):\($0.name)" }
            DiagLog.log("tracks audio=\(a) subtitle=\(s) external=\(item?.subtitleURLs.count ?? 0)", "playback")
            // External subtitle files from the server. Added here (not at start) because the
            // coordinator clears its subtitle list asynchronously when the URL is set.
            if let urls = item?.subtitleURLs, !urls.isEmpty {
                coordinator.subtitleModel.addSubtitle(dataSouce: URLSubtitleDataSouce(urls: urls))
            }
        }
    }
}
