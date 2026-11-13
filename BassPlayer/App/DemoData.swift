import Foundation

/// Sample content for simulator screenshots (CI launches the app with BASSPLAYER_DEMO=1).
/// Nothing here touches the network; artwork falls back to the generated placeholders.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["BASSPLAYER_DEMO"] == "1" }

    @MainActor
    static func apply(library: LibraryStore, jellyfin: JellyfinClient, plex: PlexClient, youtube: YouTubeClient) {
        jellyfin.enableDemo(items: jellyfinItems, server: "http://192.168.1.10:8096", shelves: shelves(jellyfinItems))
        plex.enableDemo(items: plexItems, serverName: "Homelab", shelves: shelves(plexItems))
        youtube.enableDemo(items: youtubeItems, query: "spacex launch")
        // A few things part-watched for the Continue Watching rows.
        for (item, fraction) in [(jellyfinItems[0], 0.42), (plexItems[1], 0.7), (jellyfinItems[3], 0.15)] {
            let seconds = Double(item.runtimeMinutes ?? 100) * 60 * fraction
            library.savePosition(seconds, duration: Double(item.runtimeMinutes ?? 100) * 60, for: item)
            library.noteStarted(item)
        }
        library.noteStarted(youtubeItems[2])
    }

    /// Home rows for a demo server: something in progress, newest first, etc.
    private static func shelves(_ items: [MediaItem]) -> [Shelf] {
        let movies = items.filter { !$0.isEpisode }
        let episodes = items.filter(\.isEpisode)
        var rows: [Shelf] = [
            Shelf(kind: .continueWatching, items: Array(items.prefix(2)) + episodes.prefix(1)),
            Shelf(kind: .recentlyAddedMovies, items: Array(movies.reversed())),
            Shelf(kind: .recentlyReleasedMovies, items: movies.sorted { ($0.subtitle ?? "") > ($1.subtitle ?? "") }),
            Shelf(kind: .recentlyWatched, items: Array(movies.dropFirst(2).prefix(4))),
        ]
        if episodes.count > 1 { rows.insert(Shelf(kind: .upNext, items: Array(episodes.dropFirst())), at: 1) }
        if !episodes.isEmpty { rows.insert(Shelf(kind: .recentlyReleasedEpisodes, items: episodes), at: rows.count - 1) }
        return rows
    }

    private static func movie(_ source: MediaSource, _ id: String, _ title: String, _ year: Int, _ minutes: Int,
                              container: String = "mkv", video: String = "hevc", audio: String = "truehd", channels: Int = 8,
                              range: String? = "HDR10", height: Int = 2160, stereo: StereoFormat? = nil) -> MediaItem {
        MediaItem(id: "\(source.rawValue):demo-\(id)", source: source, title: title, subtitle: String(year), overview: nil,
                  runtimeMinutes: minutes, posterURL: nil, directURL: nil, avPlayerURL: nil,
                  container: container, videoCodec: video, audioCodec: audio, audioChannels: channels, videoRange: range,
                  isEpisode: false, width: height * 16 / 9, height: height, stereo: stereo)
    }

    private static func episode(_ source: MediaSource, _ id: String, _ show: String, _ s: Int, _ e: Int, _ title: String) -> MediaItem {
        MediaItem(id: "\(source.rawValue):demo-\(id)", source: source, title: title,
                  subtitle: String(format: "%@ · S%02dE%02d", show, s, e), overview: nil,
                  runtimeMinutes: 48, posterURL: nil, directURL: nil, avPlayerURL: nil,
                  container: "mkv", videoCodec: "h264", audioCodec: "eac3", audioChannels: 6, videoRange: "SDR",
                  isEpisode: true, width: 1920, height: 1080, stereo: nil,
                  season: s, episodeNumber: e, showTitle: show)
    }

    static let jellyfinItems: [MediaItem] = [
        movie(.jellyfin, "1", "Dune: Part Two", 2024, 166, range: "Dolby Vision"),
        movie(.jellyfin, "2", "Interstellar", 2014, 169, audio: "dts", channels: 6, range: "SDR", height: 1080),
        movie(.jellyfin, "3", "Blade Runner 2049", 2017, 164),
        movie(.jellyfin, "4", "Mad Max: Fury Road", 2015, 120, range: "HDR10"),
        movie(.jellyfin, "5", "Gravity", 2013, 91, range: "SDR", height: 1080, stereo: .sbsHalf),
        movie(.jellyfin, "6", "Oppenheimer", 2023, 180),
        movie(.jellyfin, "7", "Arrival", 2016, 116, range: "SDR", height: 1080),
        movie(.jellyfin, "8", "Tenet", 2020, 150),
        episode(.jellyfin, "e1", "The Expanse", 1, 1, "Dulcinea"),
        episode(.jellyfin, "e2", "The Expanse", 1, 2, "The Big Empty"),
        episode(.jellyfin, "e3", "Severance", 2, 1, "Hello, Ms. Cobel"),
    ]

    static let plexItems: [MediaItem] = [
        movie(.plex, "1", "Top Gun: Maverick", 2022, 130, container: "mp4", range: "HDR10"),
        movie(.plex, "2", "Edge of Tomorrow", 2014, 113, range: "SDR", height: 1080),
        movie(.plex, "3", "Avatar: The Way of Water", 2022, 192, stereo: .sbsHalf),
        movie(.plex, "4", "The Dark Knight", 2008, 152),
        movie(.plex, "5", "Baby Driver", 2017, 113, range: "SDR", height: 1080),
        movie(.plex, "6", "1917", 2019, 119),
        episode(.plex, "e1", "Foundation", 1, 1, "The Emperor's Peace"),
    ]

    static let youtubeItems: [MediaItem] = [
        ("yt1", "Starship Flight 10 — full launch and catch", "SpaceX · 12M views", 48),
        ("yt2", "How subwoofers work (and why 20 Hz matters)", "Tech Ingredients · 1.2M views", 23),
        ("yt3", "Costa Rica in 4K 60fps HDR (ULTRA HD)", "Jacob + Katie Schwarz · 60M views", 5),
        ("yt4", "Dolby Atmos demo: Amaze", "Dolby · 3.4M views", 1),
        ("yt5", "The sound design of Dune", "Nerdwriter1 · 2.1M views", 11),
        ("yt6", "Apple Vision Pro, one year later", "MKBHD · 8.9M views", 19),
    ].map { id, title, channel, minutes in
        MediaItem(id: "youtube:demo-\(id)", source: .youtube, title: title, subtitle: channel, overview: nil,
                  runtimeMinutes: minutes, posterURL: nil, directURL: nil, avPlayerURL: nil,
                  container: nil, videoCodec: nil, audioCodec: nil, audioChannels: nil, videoRange: nil,
                  isEpisode: false, width: nil, height: nil, stereo: nil, needsResolve: true, youtubeId: id, userAgent: nil)
    }
}
