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

            SubtitleOverlay(model: playback.coordinator.subtitleModel, base: 26)
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
                SubtitleMenu(model: playback.coordinator.subtitleModel, coordinator: playback.coordinator, externalURLs: item.subtitleURLs)
                SubtitleSizeMenu()
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

    private func label(_ t: MediaPlayerTrack) -> String { TrackLabel.audio(t) }
}

/// Short, single-line track names for menus. Menu rows on visionOS are narrow, so these stay
/// under ~24 characters: "English · DTS-HD MA 7.1", "English · Commentary · AC-3 stereo".
enum TrackLabel {
    static func audio(_ t: MediaPlayerTrack) -> String {
        let lang = languageName(t.languageCode)
        var parts: [String] = []
        if let lang { parts.append(lang) }
        if let ff = t as? FFmpegAssetTrack {
            let codec = codecName(ff.codecName)
            let title = cleanTitle(ff.name, language: lang, code: t.languageCode)
            if let title, !sameThing(title, codec) {
                parts.append(title)
                if !mentions(title, codec) { parts.append(codec) }
            } else {
                parts.append(codec)
            }
            if let ch = ff.audioDescriptor?.audioFormat.channelCount {
                let c = channels(Int(ch))
                if !(title.map { $0.contains(c) } ?? false) { parts[parts.count - 1] += " " + c }
            }
        } else if !t.name.isEmpty {
            parts.append(String(t.name.prefix(24)))
        }
        if parts.isEmpty { parts.append("Track \(t.trackID)") }
        return parts.joined(separator: " · ")
    }

    static func subtitle(_ t: FFmpegAssetTrack) -> String {
        let lang = languageName(t.languageCode)
        var parts: [String] = []
        if let lang { parts.append(lang) }
        if let title = cleanTitle(t.name, language: lang, code: t.languageCode) { parts.append(title) }
        parts.append(t.isImageSubtitle ? "image" : codecName(t.codecName).lowercased())
        return parts.joined(separator: " · ")
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    /// The track title with the language (which the menu already shows) and marketing words
    /// removed, common codec names abbreviated, capped at 20 characters. Nil if nothing is left.
    static func cleanTitle(_ raw: String, language: String?, code: String?) -> String? {
        var s = raw
        for word in [language, code, "Audio", "Surround", "Sound", "Original", "Stereo"].compactMap({ $0 }) where word.count > 1 {
            s = s.replacingOccurrences(of: word, with: " ", options: .caseInsensitive)
        }
        for (long, short) in [("DTS-HD Master", "DTS-HD MA"), ("DTS-HD High Resolution", "DTS-HD HR"), ("Dolby TrueHD", "TrueHD"),
                              ("Dolby Digital Plus", "E-AC-3"), ("Dolby Digital", "AC-3"), ("Dolby Atmos", "Atmos"), ("Master", "MA")] {
            s = s.replacingOccurrences(of: long, with: short, options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "[\\s/|·:\\-()\\[\\]]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return String(s.prefix(20)).trimmingCharacters(in: .whitespaces)
    }

    private static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func sameThing(_ a: String, _ b: String) -> Bool { norm(a) == norm(b) }
    private static func mentions(_ title: String, _ codec: String) -> Bool { norm(title).contains(norm(codec)) }

    static func codecName(_ raw: String) -> String {
        let base = raw.split(separator: " ").first.map(String.init) ?? raw
        switch base.lowercased() {
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "truehd": return "TrueHD"
        case "dts": return raw.lowercased().contains("hd ma") ? "DTS-HD MA" : (raw.lowercased().contains("hd") ? "DTS-HD" : "DTS")
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "pcm_s16le", "pcm_s24le": return "PCM"
        default: return base.uppercased()
        }
    }

    static func channels(_ n: Int) -> String {
        switch n {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n)ch"
        }
    }
}

/// Subtitle picker: embedded tracks (from the file) and external files (from the server).
private struct SubtitleMenu: View {
    @ObservedObject var model: SubtitleModel
    let coordinator: KSVideoPlayer.Coordinator
    var externalURLs: [URL] = []

    var body: some View {
        Menu {
            Button { select(nil) } label: {
                if model.selectedSubtitleInfo == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if model.subtitleInfos.isEmpty { Text("No subtitles found") }
            ForEach(model.subtitleInfos, id: \.subtitleID) { info in
                Button { select(info) } label: {
                    if model.selectedSubtitleInfo?.subtitleID == info.subtitleID {
                        Label(name(info), systemImage: "checkmark")
                    } else {
                        Text(name(info))
                    }
                }
            }
            Divider()
            Button { rescan() } label: { Label("Rescan tracks", systemImage: "arrow.clockwise") }
        } label: {
            Image(systemName: model.selectedSubtitleInfo == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .help("Subtitles")
    }

    private func name(_ info: any SubtitleInfo) -> String {
        if let t = info as? FFmpegAssetTrack { return TrackLabel.subtitle(t) }
        return String(info.name.prefix(30))
    }

    /// Re-collect embedded tracks from the player and the server's external files.
    private func rescan() {
        let before = model.subtitleInfos.count
        if let ds = coordinator.playerLayer?.player.subtitleDataSouce { model.addSubtitle(dataSouce: ds) }
        if !externalURLs.isEmpty { model.addSubtitle(dataSouce: URLSubtitleDataSouce(urls: externalURLs)) }
        let embedded = coordinator.playerLayer?.player.tracks(mediaType: .subtitle).count ?? 0
        DiagLog.log("subtitle rescan: \(before) → \(model.subtitleInfos.count) (player reports \(embedded) subtitle tracks, \(externalURLs.count) external)", "player")
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

/// Draws the current subtitle cue(s). `base` is the point size at 100 %; the user's
/// "Subtitle size" setting scales it (shared by the window and the cinema screen).
struct SubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel
    var base: CGFloat = 26
    @AppStorage(SubtitleSize.key) private var scalePercent: Int = 100

    private var fontSize: CGFloat { base * CGFloat(scalePercent) / 100 }

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(model.parts) { part in
                if let image = part.image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: fontSize * 5)
                } else if let text = part.text {
                    // Plain string: the parsed cue carries its own font attributes (KSPlayer's
                    // textFontSize / ASS styles), which would override the size chosen here.
                    Text(text.string)
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

/// The user's subtitle size, in percent of the default. Stored once, read everywhere.
enum SubtitleSize {
    static let key = "subtitle.sizePercent"
    static let options = [60, 80, 100, 125, 150, 200]
}

/// "Aa" menu: pick the subtitle size.
struct SubtitleSizeMenu: View {
    @AppStorage(SubtitleSize.key) private var scalePercent: Int = 100

    var body: some View {
        Menu {
            Picker("Subtitle size", selection: $scalePercent) {
                ForEach(SubtitleSize.options, id: \.self) { p in
                    Text(p == 100 ? "Normal" : "\(p) %").tag(p)
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .help("Subtitle size")
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
