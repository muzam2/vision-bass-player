import SwiftUI

/// Landing screen: pick up where you left off, jump to a source, see the sub.
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink

    private var connectedSources: [MediaSource] {
        MediaSource.allCases.filter { source in
            switch source {
            case .jellyfin, .plex: return library.isSignedIn(source)
            case .youtube: return true
            case .nas: return !library.nas.shares.isEmpty
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if !library.continueWatching.isEmpty {
                        continueWatching
                    }
                    if !library.recents.isEmpty {
                        recentlyPlayed
                    }
                    sources
                    SubStatusCard()
                    if library.recents.isEmpty && connectedSources.count <= 1 {
                        gettingStarted
                    }
                }
                .padding(Metrics.pagePadding)
            }
            .navigationTitle("Bass Player")
        }
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Continue watching")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacing) {
                    ForEach(library.continueWatching.prefix(12)) { item in
                        CardButton { library.play(item) } label: {
                            PosterCard(item: item, progress: library.progress(for: item))
                                .frame(width: Metrics.posterMin)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Recently played")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacing) {
                    ForEach(library.recents.prefix(12)) { item in
                        CardButton { library.play(item) } label: {
                            PosterCard(item: item, progress: library.progress(for: item))
                                .frame(width: Metrics.posterMin)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Your sources")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: Metrics.spacing)], spacing: Metrics.spacing) {
                ForEach(MediaSource.allCases) { source in
                    SourceCard(source: source, connected: connectedSources.contains(source), status: library.status(of: source)) {
                        library.selectedTab = AppTab(source: source)
                    }
                }
            }
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Getting started")
            Text("1. Open Settings and sign in to Jellyfin or Plex, or add a NAS share.\n2. Power the subwoofer receiver; it connects by itself.\n3. Pick a film. The low end goes to the sub, everything else stays in your ears.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SourceCard: View {
    let source: MediaSource
    let connected: Bool
    let status: String
    let action: () -> Void

    var body: some View {
        CardButton(action: action) {
            HStack(spacing: 14) {
                Image(systemName: AppTab(source: source).systemImage)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(connected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(connected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.label).font(.headline)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Subwoofer link summary with a connect button.
struct SubStatusCard: View {
    @EnvironmentObject private var bassLink: BassLink

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: bassLink.state == .connected ? "hifispeaker.fill" : "hifispeaker")
                .font(.title)
                .foregroundStyle(bassLink.state == .connected ? .green : .secondary)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Subwoofer").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch bassLink.state {
            case .off:
                Button("Connect") { bassLink.start() }
            case .connected:
                Button("Disconnect") { bassLink.stop() }
            default:
                ProgressView()
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusText: String {
        switch bassLink.state {
        case .off: return "Not connected. Power the receiver and press Connect."
        case .scanning: return "Looking for the receiver…"
        case .connecting: return "Connecting…"
        case .connected:
            var s = bassLink.peripheralName ?? "Receiver"
            s += " · buffer \(bassLink.receiverBufferFill) samples"
            if bassLink.receiverUnderruns > 0 { s += " · \(bassLink.receiverUnderruns) underruns" }
            return s
        }
    }
}
