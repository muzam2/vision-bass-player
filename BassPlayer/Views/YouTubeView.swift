import SwiftUI

/// YouTube: a search box that is always there, results as a thumbnail grid, and recent
/// searches while the list is empty. There is no account and no feed; YouTube retired the
/// anonymous Trending page, so search (or a pasted link) is the way in.
struct YouTubeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var youtube: YouTubeClient
    @State private var query = ""
    @State private var recentSearches: [String] = RecentSearches.load()
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                content
            }
            .navigationTitle("YouTube")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Max quality", selection: $youtube.maxHeight) {
                            ForEach(YouTubeClient.maxHeightChoices, id: \.self) { h in
                                Text(h == 2160 ? "4K (2160p)" : "\(h)p").tag(h)
                            }
                        }
                        Toggle("HDR when available", isOn: $youtube.preferHDR)
                        Toggle("SponsorBlock", isOn: $youtube.sponsorBlockEnabled)
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
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search YouTube, or paste a link", text: $query)
                .textFieldStyle(.plain)
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

    @ViewBuilder
    private var content: some View {
        if youtube.isBusy && youtube.items.isEmpty {
            Spacer()
            ProgressView("Searching…")
            Spacer()
        } else if youtube.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: youtube.lastQuery.isEmpty ? "Results" : "Results for “\(youtube.lastQuery)”",
                                  detail: "\(youtube.items.count)")
                    LazyVGrid(columns: Metrics.videoColumns, alignment: .leading, spacing: Metrics.spacing) {
                        ForEach(youtube.items) { item in
                            CardButton { library.play(item) } label: { VideoCard(item: item) }
                        }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, Metrics.pagePadding)
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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
                if recentSearches.isEmpty && recent.isEmpty {
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
