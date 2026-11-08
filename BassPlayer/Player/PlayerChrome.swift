#if os(visionOS)
import SwiftUI
import AVFoundation
import KSPlayer

/// Bass Player's own player UI on visionOS, wrapped around KSPlayer's bare video view.
///
/// KSPlayer's stock `KSVideoPlayerView` put its subtitle/audio menus in a scene-bottom ornament
/// that collided with the app's own ornament, so on the headset neither the subtitle picker nor
/// an audio-track picker was reachable and subtitles never showed. This view draws the controls
/// itself: transport, scrubber, audio + subtitle + speed menus, the 3D / projection pickers and
/// the cinema-screen toggle. While the cinema screen is open the window turns into a remote
/// (controls + screen settings) instead of showing the picture twice.
struct FFmpegPlayerChrome: View {
    let item: MediaItem
    let url: URL
    @ObservedObject var coordinator: KSVideoPlayer.Coordinator
    @ObservedObject var session: FFmpegSession
    let options: KSOptions

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    /// Mirror of the coordinator's (non-published) state so the controls redraw on changes.
    @State private var playerState: KSPlayerState = .initialized
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showScreenSettings = false
    @State private var trackRefresh = 0

    var body: some View {
        ZStack {
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onStateChanged { layer, state in
                    playerState = state
                    DiagLog.log("state \(state) · \(item.title)", "player")
                    if state == .readyToPlay {
                        trackRefresh += 1
                        let a = layer.player.tracks(mediaType: .audio).map { "\($0.trackID):\($0.name)" }
                        let s = layer.player.tracks(mediaType: .subtitle).map { "\($0.trackID):\($0.name)" }
                        DiagLog.log("tracks audio=\(a) subtitle=\(s) external=\(item.subtitleURLs.count)", "player")
                    }
                    if state == .bufferFinished { scheduleHide() } else { showControls = true }
                }
                .ignoresSafeArea()
                .onAppear {
                    if !item.subtitleURLs.isEmpty {
                        coordinator.subtitleModel.addSubtitle(dataSouce: URLSubtitleDataSouce(urls: item.subtitleURLs))
                    }
                }

            SubtitleOverlay(model: coordinator.subtitleModel)
                .padding(.bottom, showControls ? 150 : 60)

            if immersive.isOpen {
                remotePanel
            } else {
                controls
                    .opacity(showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !immersive.isOpen else { return }
            showControls.toggle()
            if showControls { scheduleHide() }
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
            if coordinator.state == .bufferFinished { showControls = false }
        }
    }

    /// Stop: end playback, take the cinema screen down, close the player window.
    private func stop() {
        DiagLog.log("stop pressed", "player")
        coordinator.playerLayer?.pause()
        Task {
            if immersive.isOpen { await dismissImmersiveSpace() }
            dismiss()
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) { stop() } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBackgroundEffect()
    }

    // MARK: - Normal controls

    private var controls: some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                Text(item.title).font(.title3.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassBackgroundEffect()
                Spacer()
                statusChip     // fades with the controls; not on screen all the time
                stopButton
            }
            .padding(16)
            Spacer()
            transportBar
                .padding(.horizontal, 20).padding(.vertical, 14)
                .glassBackgroundEffect()
                .padding(.bottom, 24)
        }
    }

    /// While the cinema screen shows the picture, the window is a remote: controls + settings.
    private var remotePanel: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Playing on the cinema screen", systemImage: "rectangle.inset.filled.on.rectangle")
                        .font(.title3.weight(.semibold))
                    Text(item.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                statusChip
                stopButton
            }
            transportBar
            ImmersiveScreenSettings()
                .frame(maxHeight: .infinity)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Transport

    private var transportBar: some View {
        VStack(spacing: 10) {
            Scrubber(coordinator: coordinator, timemodel: coordinator.timemodel)
            HStack(spacing: 18) {
                Button { coordinator.skip(interval: -10) } label: { Image(systemName: "gobackward.10") }
                Button {
                    if playerState.isPlaying { coordinator.playerLayer?.pause() } else { coordinator.playerLayer?.play() }
                    showControls = true
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                }
                .font(.title)
                Button { coordinator.skip(interval: 30) } label: { Image(systemName: "goforward.30") }
                if playerState == .buffering { ProgressView().controlSize(.small) }
                Spacer()
                audioMenu
                subtitleMenu
                speedMenu
                Divider().frame(height: 24)
                StereoPickerMenu(item: item)
                ProjectionPickerMenu(item: item)
                ImmersiveScreenToggle(compact: true)
                Button { showScreenSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .disabled(immersive.isOpen)   // settings are inline on the remote panel
            }
            .font(.title2)
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Menus

    private var audioTracks: [MediaPlayerTrack] {
        _ = trackRefresh
        return coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    private var audioMenu: some View {
        Menu {
            if audioTracks.isEmpty {
                Text("No audio tracks yet")
            }
            ForEach(audioTracks, id: \.trackID) { track in
                Button {
                    coordinator.playerLayer?.player.select(track: track)
                    trackRefresh += 1
                    DiagLog.log("audio → \(track.trackID) \(track.name)", "player")
                } label: {
                    if track.isEnabled {
                        Label(trackLabel(track), systemImage: "checkmark")
                    } else {
                        Text(trackLabel(track))
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .help("Audio track")
    }

    private var subtitleMenu: some View {
        SubtitleMenu(model: coordinator.subtitleModel, coordinator: coordinator)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $coordinator.playbackRate) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                    Text(r == 1 ? "Normal" : String(format: "%g×", r)).tag(r)
                }
            }
        } label: {
            Image(systemName: coordinator.playbackRate == 1 ? "gauge.with.dots.needle.50percent" : "gauge.with.dots.needle.67percent")
        }
    }

    private func trackLabel(_ t: MediaPlayerTrack) -> String {
        var s = t.name
        if let lang = t.languageCode, !s.localizedCaseInsensitiveContains(lang) {
            s += " · \(Locale.current.localizedString(forLanguageCode: lang) ?? lang)"
        }
        return s
    }

    // MARK: - Status

    private var statusChip: some View {
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

/// Subtitle picker: embedded tracks (from the file) and external files (from the server).
private struct SubtitleMenu: View {
    @ObservedObject var model: SubtitleModel
    let coordinator: KSVideoPlayer.Coordinator

    var body: some View {
        Menu {
            Button { select(nil) } label: {
                if model.selectedSubtitleInfo == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if model.subtitleInfos.isEmpty {
                Text("No subtitles in this file")
            }
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

/// Draws the current subtitle cue(s) over the picture.
struct SubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            ForEach(model.parts) { part in
                if let image = part.image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                } else if let text = part.text {
                    Text(AttributedString(text))
                        .font(.system(size: 40, weight: .medium))
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
private struct Scrubber: View {
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
