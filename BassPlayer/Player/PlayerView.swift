import SwiftUI
import AVKit

struct PlayerView: View {
    let item: JellyfinItem

    @EnvironmentObject private var jellyfin: JellyfinClient
    @EnvironmentObject private var bassLink: BassLink
    @StateObject private var controller: PlayerController

    init(item: JellyfinItem) {
        self.item = item
        // StateObject needs the link at init; grab it from the shared app instance via a holder.
        _controller = StateObject(wrappedValue: PlayerController(bassLink: BassLinkHolder.shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: controller.player)
                .aspectRatio(16/9, contentMode: .fit)

            HStack(spacing: 16) {
                Text(item.Name).font(.headline)
                Spacer()
                Label(controller.tapInstalled ? "Bass tap on" : "Bass tap off",
                      systemImage: controller.tapInstalled ? "waveform" : "waveform.slash")
                    .foregroundStyle(controller.tapInstalled ? .green : .secondary)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(item.Name)
        .onAppear {
            if bassLink.state == .off { bassLink.start() }
            if let url = jellyfin.streamURL(for: item) {
                controller.load(url: url)
            }
        }
        .onDisappear { controller.stop() }
    }
}

/// Lets `PlayerView` reach the app-wide `BassLink` at `@StateObject` init time.
/// Set once in `BassPlayerApp`.
enum BassLinkHolder {
    static var shared: BassLink!
}
