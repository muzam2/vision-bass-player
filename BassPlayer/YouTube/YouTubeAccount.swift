import Foundation
import SwiftUI
import CryptoKit
#if canImport(WebKit)
import WebKit
#endif

/// Optional YouTube account, signed in through Google's own web page in a WKWebView. The
/// resulting youtube.com cookies stay in WebKit's store (sandboxed to this app); feed requests
/// (Home, Subscriptions, History, playlists) carry them plus the `SAPISIDHASH` authorization
/// YouTube's web client uses. Playback (`player`) requests stay anonymous: stream URLs don't
/// need the account and keeping them separate means nothing we do at playback can touch it.
@MainActor
final class YouTubeAccount: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var cookies: [HTTPCookie] = []

    static let origin = "https://www.youtube.com"

    init() {
        Task { await refresh() }
    }

    /// Re-read the cookie store (after sign-in / sign-out).
    func refresh() async {
        #if canImport(WebKit)
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        cookies = all.filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix(".google.com") }
        let signed = sapisid != nil
        if signed != isSignedIn { DiagLog.log(signed ? "account signed in" : "account signed out", "youtube") }
        isSignedIn = signed
        #else
        cookies = []
        isSignedIn = false
        #endif
    }

    func signOut() async {
        #if canImport(WebKit)
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() where c.domain.hasSuffix("youtube.com") || c.domain.hasSuffix(".google.com") || c.domain.hasSuffix("accounts.google.com") {
            await store.deleteCookie(c)
        }
        #endif
        await refresh()
    }

    private var sapisid: String? {
        let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        return yt.first { $0.name == "SAPISID" }?.value ?? yt.first { $0.name == "__Secure-3PAPISID" }?.value
    }

    /// Headers that make an InnerTube request act as the signed-in user (nil when signed out).
    func authHeaders() -> [String: String]? {
        guard let sapisid else { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(Self.origin)".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let cookieHeader = cookies.filter { $0.domain.hasSuffix("youtube.com") }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return [
            "Authorization": "SAPISIDHASH \(ts)_\(hash)",
            "X-Origin": Self.origin,
            "X-Goog-AuthUser": "0",
            "Cookie": cookieHeader,
        ]
    }
}

#if canImport(WebKit)
/// Google's sign-in page in a sheet; closes itself once youtube.com has a session cookie.
struct YouTubeSignInView: View {
    @EnvironmentObject private var youtube: YouTubeClient
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Loading Google sign-in…"

    var body: some View {
        NavigationStack {
            SignInWebView(status: $status) {
                Task {
                    await youtube.account.refresh()
                    if youtube.account.isSignedIn {
                        dismiss()
                        await youtube.load(feed: .home)
                    }
                }
            }
            .navigationTitle("Sign in to YouTube")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 700, minHeight: 760)
    }
}

private struct SignInWebView: UIViewRepresentable {
    @Binding var status: String
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        var comps = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        comps.queryItems = [
            .init(name: "service", value: "youtube"),
            .init(name: "hl", value: "en"),
            .init(name: "continue", value: "https://www.youtube.com/"),
        ]
        web.load(URLRequest(url: comps.url!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SignInWebView
        var done = false
        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let host = webView.url?.host ?? ""
            parent.status = host
            guard !done, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                let signed = cookies.contains { ($0.name == "SAPISID" || $0.name == "__Secure-3PAPISID") && $0.domain.hasSuffix("youtube.com") }
                if signed {
                    self.done = true
                    self.parent.onSignedIn()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.status = error.localizedDescription
        }
    }
}
#endif
