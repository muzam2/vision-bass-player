#if os(visionOS)
import SwiftUI
import AVFoundation
import KSPlayer

/// Bass Player's own player UI on visionOS, wrapped around KSPlayer's bare video view.
///
/// KSPlayer's stock `KSVideoPlayerView` put its subtitle/audio menus in a scene-bottom ornament
/// that collided with the app's own ornament, so on the headset neither the subtitle picker nor
/// an audio-track picker was reachable and subtitles never showed. This view draws the controls
/// itself (`TransportBar`), shared with the floating panel inside the cinema screen.
struct FFmpegPlayerChrome: View {
    let item: MediaItem
    let url: URL
    @ObservedObject var playback: PlaybackController
    @ObservedObject var session: FFmpegSession

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showScreenSettings = false

    var body: some View {
        ZStack {
            KSVideoPlayer(coordinator: playback.coordinator, url: url, options: session.options)
                .ignoresSafeArea()

            SubtitleOverlay(model: playback.coordinator.subtitleModel)
                .padding(.bottom, showControls ? 150 : 60)

            if immersive.isOpen {
                // Only visible for the instant before the cinema screen dismisses this window.
                Label("Playing on the cinema screen", systemImage: "rectangle.inset.filled.on.rectangle")
                    .padding(20).glassBackgroundEffect()
            } else {
                controls
                    .opacity(showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showControls.toggle()
            if showControls { scheduleHide() }
        }
        .onChange(of: playback.state, initial: true) { _, state in
            if state == .bufferFinished { scheduleHide() } else { showControls = true }
        }
        .sheet(isPresented: $showScreenSettings) {
            NavigationStack {
                ImmersiveScreenSettings()
                    .navigationTitle("Cinema screen")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showScreenSettings = false } } }
            }
            .frame(minWidth: 480, minHeight: 620)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if playback.state == .bufferFinished { showControls = false }
        }
    }

    /// Stop: end playback, take the cinema screen down, close the player window.
    private func stop() {
        DiagLog.log("stop pressed (window)", "player")
        playback.end()
        Task {
            if immersive.isOpen { await dismissImmersiveSpace() }
            dismiss()
        }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                Text(item.title).font(.title3.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassBackgroundEffect()
                Spacer()
                BassStatusChip(session: session)     // fades with the controls
                StopButton(action: stop)
            }
            .padding(16)
            Spacer()
            TransportBar(item: item, playback: playback, session: session, onScreenSettings: { showScreenSettings = true })
                .padding(.horizontal, 20).padding(.vertical, 14)
                .glassBackgroundEffect()
                .padding(.bottom, 24)
        }
    }
}

/// Transport + menus. Used by the window chrome and by the floating panel in the cinema screen.
struct TransportBar: View {
    let item: MediaItem
    @ObservedObject var playback: PlaybackController
    @ObservedObject var session: FFmpegSession
    /// Opens the screen-settings sheet (window) — nil inside the cinema screen, where the
    /// panel has its own size/distance controls.
    var onScreenSettings: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Scrubber(coordinator: playback.coordinator, timemodel: playback.coordinator.timemodel)
            HStack(spacing: 18) {
                Button { playback.coordinator.skip(interval: -10) } label: { Image(systemName: "gobackward.10") }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                }
                .font(.title)
                Button { playback.coordinator.skip(interval: 30) } label: { Image(systemName: "goforward.30") }
                if playback.state == .buffering { ProgressView().controlSize(.small) }
                Spacer()
                AudioTrackMenu(playback: playback)
                SubtitleMenu(model: playback.coordinator.subtitleModel, coordinator: playback.coordinator)
                speedMenu
                Divider().frame(height: 24)
                StereoPickerMenu(item: item)
                ProjectionPickerMenu(item: item)
                ImmersiveScreenToggle(compact: true)
                if let onScreenSettings {
                    Button(action: onScreenSettings) { Image(systemName: "slider.horizontal.3") }
                }
            }
            .font(.title2)
            .buttonStyle(.borderless)
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { playback.coordinator.playbackRate },
                set: { playback.coordinator.playbackRate = $0 }
            )) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                    Text(r == 1 ? "Normal" : String(format: "%g×", r)).tag(r)
                }
            }
        } label: {
            Image(systemName: playback.coordinator.playbackRate == 1 ? "gauge.with.dots.needle.50percent" : "gauge.with.dots.needle.67percent")
        }
    }
}

struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBackgroundEffect()
    }
}

/// Bass tap / backend / Dolby Vision summary.
struct BassStatusChip: View {
    @ObservedObject var session: FFmpegSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.tapInstalled ? "waveform" : "waveform.slash")
            Text(session.tapInstalled ? "Bass tap · \(session.audioFormat)" : "Bass tap off")
            Text("·")
            Text(session.backendName)
            if let dv = session.doviStatus { Text("·"); Text(dv) }
            if session.sponsorSkips > 0 { Text("·"); Text("Skipped \(session.sponsorSkips)") }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .foregroundStyle(session.tapInstalled ? .green : .secondary)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusChip")
    }
}

private struct AudioTrackMenu: View {
    @ObservedObject var playback: PlaybackController

    private var tracks: [MediaPlayerTrack] {
        _ = playback.state   // re-evaluate when the player state changes (tracks appear at readyToPlay)
        return playback.coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    var body: some View {
        Menu {
            if tracks.isEmpty { Text("No audio tracks yet") }
            ForEach(tracks, id: \.trackID) { track in
                Button {
                    playback.coordinator.playerLayer?.player.select(track: track)
                    DiagLog.log("audio → \(track.trackID) \(track.name)", "player")
                } label: {
                    if track.isEnabled { Label(label(track), systemImage: "checkmark") } else { Text(label(track)) }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .help("Audio track")
    }

    private func label(_ t: MediaPlayerTrack) -> String {
        var s = t.name
        if let lang = t.languageCode, !s.localizedCaseInsensitiveContains(lang) {
            s += " · \(Locale.current.localizedString(forLanguageCode: lang) ?? lang)"
        }
        return s
    }
}

/// Subtitle picker: embedded tracks (from the file) and external files (from the server).
private struct SubtitleMenu: View {
    @ObservedObject var model: SubtitleModel
    let coordinator: KSVideoPlayer.Coordinator

    var body: some View {
        Menu {
            Button { select(nil) } label: {
                if model.selectedSubtitleInfo == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if model.subtitleInfos.isEmpty { Text("No subtitles in this file") }
            ForEach(model.subtitleInfos, id: \.subtitleID) { info in
                Button { select(info) } label: {
                    if model.selectedSubtitleInfo?.subtitleID == info.subtitleID {
                        Label(info.name, systemImage: "checkmark")
                    } else {
                        Text(info.name)
                    }
                }
            }
        } label: {
            Image(systemName: model.selectedSubtitleInfo == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .help("Subtitles")
    }

    private func select(_ info: (any SubtitleInfo)?) {
        model.selectedSubtitleInfo = info
        // Image subtitles (PGS/VobSub) are decoded by the player, so the track must be selected there.
        if let track = info as? MediaPlayerTrack {
            coordinator.playerLayer?.player.select(track: track)
        }
        DiagLog.log("subtitle → \(info?.name ?? "off")", "player")
    }
}

/// Draws the current subtitle cue(s). `fontSize` scales for the cinema screen attachment.
struct SubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel
    var fontSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(model.parts) { part in
                if let image = part.image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: fontSize * 5)
                } else if let text = part.text {
                    Text(AttributedString(text))
                        .font(.system(size: fontSize, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 0)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 60)
        .allowsHitTesting(false)
    }
}

/// Seek bar bound to KSPlayer's coarse (1 s) time model; seeks on release.
struct Scrubber: View {
    let coordinator: KSVideoPlayer.Coordinator
    @ObservedObject var timemodel: ControllerTimeModel
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.clock(dragging ? Int(dragValue) : timemodel.currentTime)).monospacedDigit()
            Slider(value: Binding(
                get: { dragging ? dragValue : Double(timemodel.currentTime) },
                set: { dragValue = $0 }
            ), in: 0...Double(max(1, timemodel.totalTime))) { editing in
                dragging = editing
                if !editing { coordinator.seek(time: dragValue) }
            }
            Text(Self.clock(timemodel.totalTime)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    static func clock(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
#endif
