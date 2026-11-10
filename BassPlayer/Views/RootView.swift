import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Top level: a tab bar (visionOS: the floating side ornament that expands into a sidebar;
/// tvOS: the same adaptable style) with one destination per source plus Home and Settings.
/// Playback opens in its own window on visionOS and full screen on tvOS.
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var immersive: ImmersiveScreenModel
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
        .onChange(of: immersive.closeRequest) { _, _ in
            if immersive.isOpen { Task { await dismissImmersiveSpace() } }
        }
        .background(WindowSceneProbe { s in if let s { MainWindowTracker.shared.attach(s) } })
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { n in
            MainWindowTracker.shared.detach(n.object as? UIWindowScene)
        }
        .onAppear { immersive.reconcile(playback: library.playback, openWindow: openWindow) }
        .onChange(of: scenePhase) { _, p in if p == .active { immersive.reconcile(playback: library.playback, openWindow: openWindow) } }
        #else
        .fullScreenCover(item: $library.nowPlaying) { item in
            PlayerScreen(item: item)
                .environmentObject(library)
                .environmentObject(bassLink)
        }
        #endif
        .onAppear(perform: applyScreenOverride)
        .lookToScroll()
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

enum MainWindow {
    static let id = "library"
}

#if os(visionOS)
/// `openWindow(id:)` on a value-less WindowGroup opens *another* instance every time; three
/// callers racing to bring the library back used to leave three library windows. This knows
/// which library scenes are connected and opens one only when there is none.
@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()
    private var scenes: [ObjectIdentifier: WeakScene] = [:]
    private var lastOpen = Date.distantPast
    private struct WeakScene { weak var scene: UIWindowScene? }

    func attach(_ scene: UIWindowScene) { scenes[ObjectIdentifier(scene)] = WeakScene(scene: scene) }
    func detach(_ scene: UIWindowScene?) { if let scene { scenes[ObjectIdentifier(scene)] = nil } }

    var isOpen: Bool { scenes.values.contains { $0.scene != nil } }

    func open(_ openWindow: OpenWindowAction) {
        if isOpen { return }
        guard Date().timeIntervalSince(lastOpen) > 2 else { return }   // one in flight already
        lastOpen = Date()
        DiagLog.log("opening library window", "app")
        openWindow(id: MainWindow.id)
    }
}
#endif
