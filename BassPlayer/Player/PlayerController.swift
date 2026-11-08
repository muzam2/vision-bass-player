import Foundation
import AVFoundation
import Combine

/// Owns the AVPlayer for one film and wires its audio into the bass pipeline.
///
/// Phase 1 backend is AVPlayer (MP4/MOV, H.264/HEVC, AAC/AC-3/E-AC-3; other files are
/// remuxed by Jellyfin). Phase 2 swaps in KSPlayer/FFmpeg behind the same interface so
/// MKV/DTS/TrueHD direct-play; the BassExtractor and BassLink stay unchanged.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var status: String = "Idle"
    @Published private(set) var tapInstalled = false

    let extractor = BassExtractor()
    private let tapProcessor: BassTapProcessor
    private let bassLink: BassLink
    private var statusObservation: NSKeyValueObservation?

    init(bassLink: BassLink) {
        self.bassLink = bassLink
        self.tapProcessor = BassTapProcessor(extractor: extractor)
        // Audio-thread → BLE queue handoff. BassLink.send never blocks.
        extractor.onPacket = { [weak bassLink] packet in
            bassLink?.send(packet)
        }
    }

    func load(url: URL) {
        status = "Loading…"
        tapInstalled = false
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let item = AVPlayerItem(asset: asset)
                if let track = tracks.first, let mix = tapProcessor.makeAudioMix(for: track) {
                    item.audioMix = mix
                    tapInstalled = true
                } else {
                    // Transcoded streams sometimes expose tracks late; playback still works, just no bass yet.
                    status = "No audio track available for tap (stream may still be starting)"
                }
                observe(item)
                player.replaceCurrentItem(with: item)
                player.play()
            } catch {
                status = "Failed to load: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        tapInstalled = false
        status = "Stopped"
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.status = "Playing"
                case .failed: self.status = "Playback failed: \(item.error?.localizedDescription ?? "unknown")"
                default: break
                }
            }
        }
    }
}
