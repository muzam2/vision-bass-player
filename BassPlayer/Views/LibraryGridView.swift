import SwiftUI

/// Poster grid for a media server (Jellyfin or Plex) with always-available search,
/// a movies/TV filter and a Continue Watching row. Plex lists series as single cards that
/// open a season/episode page (`ShowEpisodesView`); Jellyfin still lists episodes.
struct LibraryGridView: View {
    let source: MediaSource
    @EnvironmentObject private var library: LibraryStore
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .title
    @State private var path: [MediaItem] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", episodes = "TV"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case title = "Title", recent = "Recently played"
        var id: String { rawValue }
    }

    private var items: [MediaItem] {
        var list = library.items(for: source)
        switch filter {
        case .all: break
        case .movies: list = list.filter { !$0.isEpisode && !$0.isShow }
        case .episodes: list = list.filter { $0.isEpisode || $0.isShow }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false) }
        }
        if sort == .recent {
            let order = Dictionary(uniqueKeysWithValues: library.recents.enumerated().map { ($1.id, $0) })
            list.sort { (order[$0.id] ?? .max, $0.title) < (order[$1.id] ?? .max, $1.title) }
        }
        return list
    }

    private var continueWatching: [MediaItem] {
        library.continueWatching.filter { $0.source == source }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !library.isSignedIn(source) {
                    NotConnectedView(source: source)
                } else if library.items(for: source).isEmpty && library.isBusy(source) {
                    ProgressView("Loading \(source.label)…")
                } else if library.items(for: source).isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "tray")
                    } description: {
                        Text("No movies or TV episodes came back from \(source.label). Check the server has video libraries, then refresh.")
                    } actions: {
                        Button("Refresh") { Task { await library.refresh(source) } }
                    }
                } else {
                    grid
                }
            }
            .navigationTitle(source.label)
            .navigationDestination(for: MediaItem.self) { ShowEpisodesView(show: $0) }
            #if !os(tvOS)
            // tvOS's .searchable takes over the top of the screen with a keyboard that sits on
            // top of the toolbar; there the search field is drawn inline above the grid instead.
            .searchable(text: $search, prompt: "Search titles")
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button { Task { await library.refresh(source) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .overlay(alignment: .bottom) { ErrorBanner(text: library.error(for: source)) }
            .task(id: source) {
                // Plex series are single cards, so "All" stays tidy there.
                filter = (source == .plex || library.showEpisodes) ? .all : .movies
                if library.isSignedIn(source) && library.items(for: source).isEmpty { await library.refresh(source) }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                #if os(tvOS)
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search titles", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                #endif
                if search.isEmpty && !continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Continue watching")
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Metrics.spacing) {
                                ForEach(continueWatching.prefix(12)) { item in
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
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: search.isEmpty ? "Library" : "Results",
                                  detail: library.isBusy(source) ? "\(items.count) · loading…" : "\(items.count)")
                    if items.isEmpty {
                        Text("No titles match “\(search)”.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Metrics.posterColumns, alignment: .leading, spacing: Metrics.spacing) {
                        ForEach(items) { item in
                            CardButton { open(item) } label: {
                                PosterCard(item: item, progress: library.progress(for: item))
                            }
                        }
                    }
                }
            }
            .padding(Metrics.pagePadding)
        }
        .refreshable { await library.refresh(source) }
    }

    private func open(_ item: MediaItem) {
        if item.isShow { path.append(item) } else { library.play(item) }
    }
}

/// A series: poster, overview, a play/continue button, then episodes grouped by season.
struct ShowEpisodesView: View {
    let show: MediaItem
    @EnvironmentObject private var library: LibraryStore
    @State private var episodes: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    private var seasons: [(number: Int, episodes: [MediaItem])] {
        Dictionary(grouping: episodes) { $0.season ?? 0 }
            .sorted { ($0.key == 0 ? Int.max : $0.key) < ($1.key == 0 ? Int.max : $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// The last-played episode if unfinished, else the one after it, else the first.
    private var upNext: MediaItem? {
        if let last = library.recents.first(where: { $0.parentShowKey == show.showKey }),
           let i = episodes.firstIndex(where: { $0.id == last.id }) {
            if (library.progress(for: episodes[i]) ?? 0) < 0.9 { return episodes[i] }
            return i + 1 < episodes.count ? episodes[i + 1] : nil
        }
        return episodes.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if loading && episodes.isEmpty {
                    ProgressView("Loading episodes…").frame(maxWidth: .infinity)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(seasons, id: \.number) { season in
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: season.number == 0 ? "Specials" : "Season \(season.number)",
                                      detail: "\(season.episodes.count)")
                        LazyVGrid(columns: Metrics.videoColumns, alignment: .leading, spacing: Metrics.spacing) {
                            ForEach(season.episodes) { ep in
                                CardButton { library.play(ep) } label: {
                                    EpisodeCard(item: ep, progress: library.progress(for: ep))
                                }
                            }
                        }
                    }
                }
            }
            .padding(Metrics.pagePadding)
        }
        .navigationTitle(show.title)
        .task { await load(refresh: false) }
        .refreshable { await load(refresh: true) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            Artwork(url: show.posterURL, title: show.title, aspect: 2 / 3)
                .frame(width: Metrics.posterMax)
            VStack(alignment: .leading, spacing: 12) {
                Text(show.title).font(.largeTitle.weight(.semibold))
                if let s = show.subtitle, !s.isEmpty { Text(s).foregroundStyle(.secondary) }
                if let o = show.overview, !o.isEmpty {
                    Text(o).foregroundStyle(.secondary).lineLimit(6)
                }
                if let next = upNext {
                    Button { library.play(next) } label: {
                        Label(next.id == episodes.first?.id && library.progress(for: next) == nil
                              ? "Play"
                              : "Continue · \(next.episodeCode)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func load(refresh: Bool) async {
        loading = true
        defer { loading = false }
        do {
            episodes = try await library.plex.episodes(of: show, refresh: refresh)
            error = episodes.isEmpty ? "No playable episodes in this series." : nil
        } catch {
            self.error = "Couldn't load episodes: \(error.localizedDescription)"
        }
    }
}

/// 16:9 episode still with "E3 · Title", runtime and progress.
struct EpisodeCard: View {
    let item: MediaItem
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: item.posterURL, title: item.title, aspect: 16 / 9)
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).tint(.white).padding(.horizontal, 10).padding(.bottom, 8)
                    }
                }
            Text(item.episodeNumber.map { "\($0). \(item.title)" } ?? item.title)
                .font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            if let r = item.runtimeText { Text(r).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension MediaItem {
    /// "S02E05" for episodes with numbers, otherwise the title.
    var episodeCode: String {
        guard let s = season, let e = episodeNumber else { return title }
        return String(format: "S%02dE%02d", s, e)
    }
}

/// Shown when a server source has no credentials yet.
struct NotConnectedView: View {
    let source: MediaSource
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("\(source.label) isn't connected", systemImage: AppTab(source: source).systemImage)
        } description: {
            Text(source == .plex && library.plex.isSignedIn
                 ? "You're signed in to Plex but no server is selected yet."
                 : "Sign in once in Settings; your library appears here.")
        } actions: {
            if source == .plex && library.plex.isSignedIn {
                Button("Find my servers") { Task { await library.plex.discoverServers() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") { library.selectedTab = .settings }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
