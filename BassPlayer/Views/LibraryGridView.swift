import SwiftUI

/// Poster grid for a media server (Jellyfin or Plex) with always-available search,
/// a movies/episodes filter and a Continue Watching row.
struct LibraryGridView: View {
    let source: MediaSource
    @EnvironmentObject private var library: LibraryStore
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .title

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", episodes = "Episodes"
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
        case .movies: list = list.filter { !$0.isEpisode }
        case .episodes: list = list.filter(\.isEpisode)
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
        NavigationStack {
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
            .searchable(text: $search, prompt: "Search titles")
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
                filter = library.showEpisodes ? .all : .movies
                if library.isSignedIn(source) && library.items(for: source).isEmpty { await library.refresh(source) }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
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
                    SectionHeader(title: search.isEmpty ? "Library" : "Results", detail: "\(items.count)")
                    if items.isEmpty {
                        Text("No titles match “\(search)”.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Metrics.posterColumns, alignment: .leading, spacing: Metrics.spacing) {
                        ForEach(items) { item in
                            CardButton { library.play(item) } label: {
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
