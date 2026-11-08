import SwiftUI

/// Top level: a tab bar (visionOS: the floating side ornament that expands into a sidebar;
/// tvOS: the same adaptable style) with one destination per source plus Home and Settings.
/// Playback opens in its own window on visionOS and full screen on tvOS.
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        TabView(selection: $library.selectedTab) {
            Tab(value: AppTab.home) { HomeView() } label: { tabLabel(.home) }
            Tab(value: AppTab.jellyfin) { LibraryGridView(source: .jellyfin) } label: { tabLabel(.jellyfin) }
            Tab(value: AppTab.plex) { LibraryGridView(source: .plex) } label: { tabLabel(.plex) }
            Tab(value: AppTab.youtube) { YouTubeView() } label: { tabLabel(.youtube) }
            Tab(value: AppTab.nas) { NASBrowserView() } label: { tabLabel(.nas) }
            Tab(value: AppTab.settings) { SettingsView() } label: { tabLabel(.settings) }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) { BassStatusOrnament() }
        .onChange(of: library.playCounter) { _, _ in
            if let item = library.nowPlaying { openWindow(id: PlayerWindow.id, value: item) }
        }
        #else
        .fullScreenCover(item: $library.nowPlaying) { item in
            PlayerScreen(item: item)
                .environmentObject(library)
                .environmentObject(bassLink)
        }
        #endif
        .onAppear(perform: applyScreenOverride)
    }

    private func tabLabel(_ tab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
    }

    /// CI screenshots launch the app with BASSPLAYER_SCREEN=<tab> to land on a given screen.
    private func applyScreenOverride() {
        if let raw = ProcessInfo.processInfo.environment["BASSPLAYER_SCREEN"], let tab = AppTab(rawValue: raw) {
            library.selectedTab = tab
        }
    }
}

enum PlayerWindow {
    static let id = "player"
}
