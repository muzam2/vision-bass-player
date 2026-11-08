import SwiftUI

/// YouTube: a search box that is always there, results as a thumbnail grid, and — once signed
/// in — the account feeds (Home, Subscriptions, History, Watch later, Liked, Playlists) as tabs.
/// Signed out, the empty state shows recent searches; YouTube retired the anonymous Trending
/// page and its anonymous Home is empty, so there is no feed without an account.
struct YouTubeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var youtube: YouTubeClient
    @State private var query = ""
    @State private var recentSearches: [String] = RecentSearches.load()
    @State private var showSignIn = false
    @FocusState private var searchFocused: Bool

    private var signedIn: Bool { youtube.account.isSignedIn }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                if signedIn {
                    feedTabs
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 12)
                }
                content
                    .padding(.top, 16)
            }
            .navigationTitle("YouTube")
            .task {
                if let q = ProcessInfo.processInfo.environment["BASSPLAYER_E2E_YT_QUERY"], !q.isEmpty, youtube.items.isEmpty {
                    query = q
                    submit(q)
                } else if signedIn, youtube.items.isEmpty, youtube.feed == .search, youtube.lastQuery.isEmpty {
                    await youtube.load(feed: .home)
                }
            }
            .onChange(of: signedIn) { _, now in
                if now, youtube.items.isEmpty { Task { await youtube.load(feed: .home) } }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if canImport(WebKit)
                    if !signedIn {
                        Button { showSignIn = true } label: { Label("Sign in", systemImage: "person.crop.circle.badge.plus") }
                    }
                    #endif
                    Menu {
                        Picker("Max quality", selection: $youtube.maxHeight) {
                            ForEach(YouTubeClient.maxHeightChoices, id: \.self) { h in
                                Text(h == 2160 ? "4K (2160p)" : "\(h)p").tag(h)
                            }
                        }
                        Toggle("HDR when available", isOn: $youtube.preferHDR)
                        Toggle("SponsorBlock", isOn: $youtube.sponsorBlockEnabled)
                        if signedIn {
                            Divider()
                            Button("Refresh") { Task { await youtube.loadLibrary() } }
                            Button("Sign out of YouTube", role: .destructive) { Task { await youtube.signOutAccount() } }
                        }
                    } label: {
                        Label("Playback options", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // Hints ("search or paste a link") are shown inline, so only real errors get the banner.
                if let e = youtube.errorMessage, !youtube.items.isEmpty || e.hasPrefix("YouTube:") {
                    ErrorBanner(text: e)
                }
            }
            #if canImport(WebKit)
            .sheet(isPresented: $showSignIn) { YouTubeSignInView() }
            #endif
        }
    }

    // MARK: - Search bar + feed tabs

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search YouTube, or paste a link", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("youtubeSearch")
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { submit(query) }
                #if !os(tvOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !query.isEmpty {
                Button { query = ""; youtube.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            #if !os(tvOS)
            Button {
                if let s = UIPasteboard.general.string, !s.isEmpty { query = s; submit(s) }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            #endif
            Button("Search") { submit(query) }
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }

    private var feedTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(YouTubeClient.Feed.accountFeeds, id: \.self) { f in
                    let selected = isCurrent(f)
                    Button {
                        Task { await youtube.load(feed: f) }
                    } label: {
                        Label(f.label, systemImage: f.systemImage)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : .secondary)
                }
                if case .playlist(_, let title) = youtube.feed {
                    Label(title, systemImage: "music.note.list")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func isCurrent(_ f: YouTubeClient.Feed) -> Bool {
        if case .playlist = youtube.feed { return f == .playlists }
        return youtube.feed == f
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if youtube.isBusy && youtube.items.isEmpty && youtube.playlists.isEmpty {
            Spacer()
            ProgressView(youtube.feed == .search ? "Searching…" : "Loading \(youtube.feed.label)…")
            Spacer()
        } else if youtube.feed == .playlists {
            playlistGrid
        } else if youtube.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: resultsTitle, detail: "\(youtube.items.count)")
                    LazyVGrid(columns: Metrics.videoColumns, alignment: .leading, spacing: Metrics.spacing) {
                        ForEach(youtube.items) { item in
                            CardButton { library.play(item) } label: { VideoCard(item: item) }
                        }
                    }
                    if youtube.canLoadMore {
                        HStack {
                            Spacer()
                            Button {
                                Task { await youtube.loadMore() }
                            } label: {
                                if youtube.isBusy { ProgressView() } else { Label("Load more", systemImage: "arrow.down.circle") }
                            }
                            .buttonStyle(.bordered)
                            .disabled(youtube.isBusy)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, Metrics.pagePadding)
            }
            .refreshable { await youtube.loadLibrary() }
        }
    }

    private var resultsTitle: String {
        switch youtube.feed {
        case .search: return youtube.lastQuery.isEmpty ? "Results" : "Results for “\(youtube.lastQuery)”"
        default: return youtube.feed.label
        }
    }

    private var playlistGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Playlists", detail: "\(youtube.playlists.count)")
                if youtube.playlists.isEmpty {
                    Text("No playlists found on this account.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Metrics.videoColumns, alignment: .leading, spacing: Metrics.spacing) {
                    ForEach(youtube.playlists) { p in
                        CardButton {
                            Task { await youtube.load(feed: .playlist(id: p.id, title: p.title)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Artwork(url: p.thumbnailURL, title: p.title, aspect: 16 / 9)
                                    .overlay(alignment: .bottomTrailing) {
                                        if let c = p.countText {
                                            Label(c, systemImage: "music.note.list")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                                                .foregroundStyle(.white)
                                                .padding(8)
                                        }
                                    }
                                Text(p.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, Metrics.pagePadding)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if canImport(WebKit)
                if !signedIn {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sign in for your Home, Subscriptions, History and playlists").font(.headline)
                            Text("Google's own sign-in page opens here. Playback stays ad-free and anonymous; the account is only used to list your feeds.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign in") { showSignIn = true }.buttonStyle(.borderedProminent)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                #endif
                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionHeader(title: "Recent searches")
                            Button("Clear") { recentSearches = []; RecentSearches.save([]) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).font(.subheadline)
                        }
                        FlowLayout(spacing: 10) {
                            ForEach(recentSearches, id: \.self) { s in
                                Button(s) { query = s; submit(s) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                let recent = library.recents.filter { $0.source == .youtube }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Recently played")
                        LazyVGrid(columns: Metrics.videoColumns, alignment: .leading, spacing: Metrics.spacing) {
                            ForEach(recent.prefix(8)) { item in
                                CardButton { library.play(item) } label: { VideoCard(item: item) }
                            }
                        }
                    }
                }
                if recentSearches.isEmpty && recent.isEmpty && youtube.feed == .search {
                    ContentUnavailableView {
                        Label("Search YouTube", systemImage: "play.tv")
                    } description: {
                        Text("Type a search above, or paste a video link. Streams play ad-free at up to 4K, and the sub gets the low end as with films.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, Metrics.pagePadding)
        }
    }

    private func submit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchFocused = false
        if InnerTubeClient.videoId(from: q) == nil {
            recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
            recentSearches.insert(q, at: 0)
            recentSearches = Array(recentSearches.prefix(10))
            RecentSearches.save(recentSearches)
        }
        Task { await youtube.search(q) }
    }
}

private enum RecentSearches {
    static let key = "yt.recentSearches"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func save(_ v: [String]) { UserDefaults.standard.set(v, forKey: key) }
}

/// Wrapping row layout for the recent-search chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
