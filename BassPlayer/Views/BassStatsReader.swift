import SwiftUI

/// Redraws its content whenever the Bluetooth link's counters change. `BassLink` itself does not
/// publish them (see `BassLink.stats`), so a view that shows a counter wraps that part in this.
struct BassStatsReader<Content: View>: View {
    @ObservedObject var stats: BassLinkStats
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
