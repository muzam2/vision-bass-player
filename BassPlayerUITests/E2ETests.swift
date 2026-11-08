import XCTest

/// End-to-end checks run in the visionOS simulator by `.github/workflows/e2e-tests.yml`.
///
/// The simulator lives on a cloud runner, so the owner's LAN servers are out of reach. The
/// workflow stands in where it can: a Samba share on the runner for the NAS path (the same
/// libsmbclient code the headset runs), the real YouTube for the YouTube path, and Plex via
/// plex.tv remote access when a token is supplied (`TEST_RUNNER_E2E_PLEX_TOKEN`). Each test
/// ends with a screenshot attachment and a liveness check of the app process.
final class E2ETests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(screen: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var launchEnv = ["BASSPLAYER_UITEST": "1", "BASSPLAYER_SCREEN": screen]
        launchEnv.merge(extra) { $1 }
        app.launchEnvironment = launchEnv
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func firstCard(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        let card = app.descendants(matching: .any).matching(identifier: "card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "no media card appeared within \(Int(timeout)) s")
        return card
    }

    /// Waits for the player's status chip, lets playback run, then checks the process is still
    /// alive and reports what the chip said.
    private func expectPlayback(_ app: XCUIApplication, name: String, chipTimeout: TimeInterval = 60) {
        let chip = app.descendants(matching: .any).matching(identifier: "statusChip").firstMatch
        let appeared = chip.waitForExistence(timeout: chipTimeout)
        attach(app, "\(name)-player")
        XCTAssertEqual(app.state, .runningForeground, "\(name): the app is no longer running (crash?)")
        XCTAssertTrue(appeared, "\(name): the player chip never appeared")
        sleep(15)
        XCTAssertEqual(app.state, .runningForeground, "\(name): the app died during playback")
        attach(app, "\(name)-player-15s")
        let label = chip.label
        print("E2E \(name): chip = \(label)")
        XCTAssertTrue(label.contains("FFmpeg") || label.contains("AVPlayer"), "\(name): chip shows no backend: \(label)")
        // Soft signal, recorded not asserted: the bass tap only engages once audio is flowing.
        if !label.contains("Bass tap ·") { print("E2E \(name): bass tap not engaged after 15 s") }
    }

    // MARK: - Tests

    func testTabsRender() {
        let app = launch(screen: "home", extra: ["BASSPLAYER_DEMO": "1"])
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 20))
        attach(app, "home")
        for tab in ["Jellyfin", "Plex", "YouTube", "NAS", "Settings"] {
            let button = app.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(tab) missing")
            button.tap()
            sleep(2)
            attach(app, tab.lowercased())
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testYouTubeSearchAndPlay() {
        let app = launch(screen: "youtube")
        let field = app.textFields["youtubeSearch"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "YouTube search field missing")
        field.tap()
        field.typeText("big buck bunny 4k 60fps\n")
        attach(app, "youtube-searching")
        let card = firstCard(in: app, timeout: 45)
        attach(app, "youtube-results")
        card.tap()
        expectPlayback(app, name: "youtube")
    }

    func testNASBrowseAndPlay() throws {
        guard let host = env["E2E_SMB_HOST"], !host.isEmpty else {
            throw XCTSkip("E2E_SMB_HOST not set; the workflow starts a Samba share and sets it")
        }
        let share = env["E2E_SMB_SHARE"] ?? "video"
        let file = env["E2E_SMB_FILE"] ?? "sample.mp4"

        let app = launch(screen: "nas")
        let add = app.buttons["Add share"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add share button missing")
        add.tap()
        let name = app.textFields["nasName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "share editor did not open")
        name.tap(); name.typeText("CI")
        let address = app.textFields["nasAddress"].firstMatch
        address.tap(); address.typeText(host)
        attach(app, "nas-editor")
        app.buttons["Save"].firstMatch.tap()

        let row = app.staticTexts["CI"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "saved share not listed")
        row.tap()
        let shareRow = app.staticTexts[share].firstMatch
        XCTAssertTrue(shareRow.waitForExistence(timeout: 30), "host-only address did not list the share '\(share)'")
        attach(app, "nas-shares")
        shareRow.tap()
        let fileRow = app.staticTexts[file].firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 30), "file '\(file)' not listed in the share")
        attach(app, "nas-files")
        fileRow.tap()
        expectPlayback(app, name: "nas")
    }

    func testPlexLibraryAndPlay() throws {
        guard let token = env["E2E_PLEX_TOKEN"], !token.isEmpty else {
            throw XCTSkip("E2E_PLEX_TOKEN not set (repository secret PLEX_TOKEN); Plex test skipped")
        }
        let app = launch(screen: "plex", extra: ["BASSPLAYER_PLEX_TOKEN": token])
        let find = app.buttons["Find my servers"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 20), "Plex 'Find my servers' button missing (token not accepted?)")
        find.tap()
        attach(app, "plex-discovering")
        let card = firstCard(in: app, timeout: 90)
        attach(app, "plex-library")
        card.tap()
        expectPlayback(app, name: "plex", chipTimeout: 90)
    }
}
