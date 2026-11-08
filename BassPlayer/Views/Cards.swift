import SwiftUI

/// Grid metrics per platform: tvOS sits 3 m away, visionOS at arm's length.
enum Metrics {
    #if os(tvOS)
    static let posterMin: CGFloat = 220
    static let posterMax: CGFloat = 260
    static let videoMin: CGFloat = 400
    static let videoMax: CGFloat = 480
    static let spacing: CGFloat = 40
    static let pagePadding: CGFloat = 60
    #else
    static let posterMin: CGFloat = 150
    static let posterMax: CGFloat = 190
    static let videoMin: CGFloat = 280
    static let videoMax: CGFloat = 340
    static let spacing: CGFloat = 24
    static let pagePadding: CGFloat = 28
    #endif

    static var posterColumns: [GridItem] { [GridItem(.adaptive(minimum: posterMin, maximum: posterMax), spacing: spacing)] }
    static var videoColumns: [GridItem] { [GridItem(.adaptive(minimum: videoMin, maximum: videoMax), spacing: spacing)] }
}

/// A button that looks right as a grid cell on each platform (focus/hover handled by the system).
struct CardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .accessibilityIdentifier("card")
        #if os(tvOS)
            .buttonStyle(.card)
        #else
            .buttonStyle(.plain)
            .hoverEffect()
        #endif
    }
}

/// Artwork with a tasteful fallback: a gradient derived from the title plus its initials.
struct Artwork: View {
    let url: URL?
    let title: String
    let aspect: CGFloat
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            placeholder
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        let hue = Double(abs(title.hashValue) % 360) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                       Color(hue: hue, saturation: 0.6, brightness: 0.25)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Text(initials)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// Poster + title + one line of detail. Optional progress bar over the poster.
struct PosterCard: View {
    let item: MediaItem
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: item.posterURL, title: item.title, aspect: 2 / 3)
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress)
                            .tint(.white)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge = item.cornerBadge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// 16:9 thumbnail card for YouTube results.
struct VideoCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: item.posterURL, title: item.title, aspect: 16 / 9)
                .overlay(alignment: .bottomTrailing) {
                    if let r = item.runtimeText {
                        Text(r)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Section header used on Home and library screens.
struct SectionHeader: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.semibold))
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
    }
}

/// Non-blocking error strip at the bottom of a screen.
struct ErrorBanner: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.orange)
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension MediaItem {
    /// Year / show info plus runtime, e.g. "2019 · 2h 10m".
    var detailLine: String {
        [subtitle, runtimeText].compactMap { $0 }.joined(separator: " · ")
    }

    /// The one thing worth shouting about on the poster: 3D, HDR flavour, or 4K.
    var cornerBadge: String? {
        if let st = stereo, st.isStereo { return "3D" }
        if let r = videoRange, r.uppercased() != "SDR" { return r == "Dolby Vision" ? "DV" : r }
        if let h = height, h >= 2000 { return "4K" }
        return nil
    }
}
