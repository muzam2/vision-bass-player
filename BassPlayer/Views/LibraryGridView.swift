import SwiftUI

/// A media server (Jellyfin or Plex), laid out like the native apps: a **Home** page of rows
/// (Continue Watching, Up Next, Recently Added / Released / Watched, each with "See all") and
/// a **Library** page with the full poster grid, a movies/TV filter and sorting. Typing in
/// search shows library results. Series are single cards that open `ShowEpisodesView`.
struct LibraryGridView: View {
    let source: MediaSource
    @EnvironmentObject private var library: LibraryStore
    @State private var search = ""
    @State private var mode: Mode = .home
    @State private var filter: Filter = .all
    @State private var sort: Sort = .title
    @State private var path = NavigationPath()

    enum Mode: String, CaseIterable, Identifiable {
        case home = "Home", library = "Library"
        var id: String { rawValue }
    }

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

    /// Library mode, or a search typed while on Home.
    private var showsLibrary: Bool {
        mode == .library || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !library.isSignedIn(source) {
                    NotConnectedView(source: source)
                } else if showsLibrary {
                    libraryContent
                } else {
                    home
                }
            }
            .navigationTitle(source.label)
            .navigationDestination(for: MediaItem.self) { ShowEpisodesView(show: $0) }
            .navigationDestination(for: ShelfLink.self) { ShelfGridView(link: $0) }
            #if !os(tvOS)
            // tvOS's .searchable takes over the top of the screen with a keyboard that sits on
            // top of the toolbar; there the search field is drawn inline above the grid instead.
            .searchable(text: $search, prompt: "Search titles")
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if library.isSignedIn(source) {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if mode == .library {
                            Picker("Show", selection: $filter) {
                                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        Menu {
                            if mode == .library {
                                Picker("Sort", selection: $sort) {
                                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                                }
                            }
                            Button { Task { await refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) { ErrorBanner(text: library.error(for: source)) }
            .task(id: source) {
                // Series are single cards, so "All" stays tidy.
                filter = .all
                guard library.isSignedIn(source) else { return }
                // Rows are re-fetched when the tab comes back after a minute (and right after
                // playback stops, see LibraryStore.report); the full list only when empty.
                async let rows: Void = library.refreshShelves(source, ifOlderThan: 60)
                if library.items(for: source).isEmpty { await library.refresh(source) }
                await rows
            }
        }
    }

    private func refreshAll() async {
        async let rows: Void = library.refreshShelves(source)
        await library.refresh(source)
        await rows
    }

    // MARK: Home

    private var home: some View {
        let shelves = library.shelves(for: source)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                if shelves.isEmpty {
                    if library.isLoadingShelves(source) || library.isBusy(source) {
                        ProgressView("Loading \(source.label)…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        ContentUnavailableView {
                            Label("Nothing to show yet", systemImage: "rectangle.stack")
                        } description: {
                            Text("\(source.label) didn't return any recent or in-progress titles.")
                        } actions: {
                            Button("Browse the library") { mode = .library }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                ForEach(shelves) { shelf in
                    ShelfRow(source: source, shelf: shelf)
                }
            }
            .padding(Metrics.pagePadding)
        }
        .refreshable { await library.refreshShelves(source) }
    }

    // MARK: Library

    @ViewBuilder
    private var libraryContent: some View {
        if library.items(for: source).isEmpty && library.isBusy(source) {
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
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: search.isEmpty ? "Library" : "Results",
                                  detail: library.isBusy(source) ? "\(items.count) · loading…" : "\(items.count)")
                    if items.isEmpty {
                        Text("No titles match “\(search)”.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Metrics.posterColumns, alignment: .leading, spacing: Metrics.spacing) {
                        ForEach(items) { item in
                            OpenItemButton(item: item) {
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
}

/// One Home row: header with "See all", then a horizontal strip of cards.
struct ShelfRow: View {
    let source: MediaSource
    let shelf: Shelf
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(shelf.title).font(.title2.weight(.semibold))
                Spacer()
                NavigationLink(value: ShelfLink(source: source, kind: shelf.kind)) {
                    Text("See all")
                }
                #if os(tvOS)
                .buttonStyle(.plain)
                #else
                .buttonStyle(.borderless)
                #endif
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacing) {
                    ForEach(shelf.items) { item in
                        OpenItemButton(item: item) {
                            if shelf.kind.isLandscape {
                                LandscapeCard(item: item, progress: library.displayProgress(for: item))
                                    .frame(width: Metrics.videoMin)
                            } else {
                                PosterCard(item: item, progress: library.displayProgress(for: item))
                                    .frame(width: Metrics.posterMin)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }
}

/// "See all" for a Home row: the whole list as a grid, fetched from the server.
struct ShelfGridView: View {
    let link: ShelfLink
    @EnvironmentObject private var library: LibraryStore
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading && items.isEmpty {
                    ProgressView("Loading…").frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if items.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: link.kind.isLandscape ? Metrics.videoColumns : Metrics.posterColumns,
                          alignment: .leading, spacing: Metrics.spacing) {
                    ForEach(items) { item in
                        OpenItemButton(item: item) {
                            if link.kind.isLandscape {
                                LandscapeCard(item: item, progress: library.displayProgress(for: item))
                            } else {
                                PosterCard(item: item, progress: library.displayProgress(for: item))
                            }
                        }
                    }
                }
            }
            .padding(Metrics.pagePadding)
        }
        .navigationTitle(link.kind.title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        // Demo mode (simulator screenshots) has no server: show the row as it is.
        if let shelf = library.shelves(for: link.source).first(where: { $0.kind == link.kind }), items.isEmpty {
            items = shelf.items
        }
        loading = true
        defer { loading = false }
        do {
            let all = try await library.shelfItems(link)
            if !all.isEmpty || items.isEmpty { items = all }
            error = nil
        } catch {
            self.error = "Couldn't load \(link.kind.title.lowercased()): \(error.localizedDescription)"
        }
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
            episodes = try await library.episodes(of: show, refresh: refresh)
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
            Artwork(url: item.artURL ?? item.posterURL, title: item.title, aspect: 16 / 9)
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
