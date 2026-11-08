# Bass Player — notes for Claude Code

Read `docs/HANDOFF.md` first: it has the full state, decisions, open risks and the next-step
list. This file is the short version.

## What this is
visionOS + tvOS video player (SwiftUI, vendored KSPlayer/FFmpeg) that streams sub-bass over
BLE to an ESP32 receiver wired to a powered subwoofer. Sources: Jellyfin, Plex, YouTube
(InnerTube), NAS (SMB/WebDAV). Vision Pro gets a RealityKit cinema screen with 3D and VR.
Owner has **no Mac**: everything is compiled by GitHub Actions and sideloaded with a free
Apple ID (Vision Pro: SideStore 0.7.2 installs the IPA downloaded in Safari from the LAN
helper `tools/diag_receiver.py`; HANDOFF §0 has the exact loop). Installed on the headset
2026-11-08 and iterated all day with a live log stream; the ESP32 receiver hasn't arrived,
so the bass path is untested.

## Build & verify
- Never try to build Swift locally; push and read Actions. `build.yml` (visionOS + tvOS unsigned
  IPAs) runs on pushes to `main`, PRs, `v*` tags and `workflow_dispatch`. `firmware.yml` builds
  both ESP32 targets when `firmware/**` changes.
- Feature work goes on a branch; trigger it with `gh workflow run build.yml --ref <branch>`,
  then merge `--no-ff` to `main` once both jobs are green.
- When polling Actions, wait 30 s between checks, not 10.
- Compile errors: `gh run view <id> --log-failed | grep "error:"`. Expect Xcode 26 / visionOS
  SDK on `macos-15` + `setup-xcode@latest-stable`.
- The IPA packaging step prints app size, `FFmpeg: linked` and one `embedded: X` line per
  dynamic framework the binary loads; it **fails** if a loaded framework is missing from
  `Frameworks/` (a dynamic SwiftPM product that the generated project did not embed = dyld
  crash at launch; that is why AMSMB2 is vendored as a static library).
- **Look at the UI before shipping it:** `gh workflow run ui-screenshots.yml --ref <branch>`
  builds for the visionOS + tvOS simulators and uploads a PNG per tab (demo data via
  `BASSPLAYER_DEMO=1`, tab via `BASSPLAYER_SCREEN`). Download the `screenshots-*` artifacts and
  read the images. New screens should be added to `DemoData` and the workflow's screen list.
- Tag pushes and release creation were blocked for the original agent session; the owner can
  push a `v*` tag himself to get a GitHub release with IPAs + firmware attached.

## Hard-won facts (don't rediscover)
- KSPlayer is **vendored** at `Vendor/KSPlayer` (from the `GPLv3` branch; upstream `main`
  now ships a binary xcframework, so its FFmpeg-facing code is no longer available as source
  — our copy is the source of truth) and patched for Dolby Vision P5, one-eye crop, a frame
  sink for the cinema screen, FFmpeg 9 API, the MVC decoder (`MEPlayer/Edge264Decode.swift`)
  and a few lifecycle fixes (`keepsPlayerWhenViewGoesAway`, no player resurrection in
  `updateUIView`, display link at panel rate on visionOS). Patched files: HANDOFF §3.
- Dolby Vision P5 needs `KSOptions.asynchronousDecompression = false` (FFmpeg hwaccel path),
  otherwise the RPU side data never reaches the frame. P7/P8 play as HDR10/HLG base layer.
- `KSVideoPlayerView` overwrites `coordinator.onStateChanged`; `FFmpegSession` therefore polls
  `coordinator.playerLayer` every 0.5 s (tap attach, crop, progress, SponsorBlock, finish).
- `AudioEnginePlayer` is `public` not `open`: tap `engine.mainMixerNode` from outside; don't
  subclass. Lead compensation rewires mixer → `AVAudioUnitDelay` → output and sets
  `options.videoDelay`.
- `MTAudioProcessingTapCreate` returns `MTAudioProcessingTap?` directly in the Xcode 26 SDK.
- `@AppStorage` inside an `ObservableObject` doesn't publish; use `@Published` + `UserDefaults`.
- tvOS has no `Stepper`, `.ornament`, `.glassBackgroundEffect`; guard with `#if os(visionOS)`
  / `#if os(tvOS)`. All immersive/ARKit code is `#if os(visionOS)`.
- The immersive-space origin is on the **floor**. The screen sits on the *gaze line*:
  `recentre` takes yaw **and pitch** from ARKit's device anchor (retry until tracked — the
  anchor is nil for the first few hundred ms), `height` is an offset from that line, dragging
  moves the screen on a sphere around the viewer. The cinema dismisses both windows and
  brings them back via `ImmersiveScreenModel.noteClosed` (idempotent; onDisappear of the
  space is not always delivered, so every exit path calls it and windows `reconcile()`).
- Cinema video path (OpenImmersive-style): decoded frames → `CMSampleBuffer` with APMP
  extensions (`viewPackingKind` for SBS/TAB, `projectionKind` for VR) → `AVSampleBufferVideoRenderer`
  → `VideoMaterial` on a flat/curved/sphere mesh. The old `StereoScreen.usda` + CoreImage path
  is gone. Flat windows still crop one eye with `MetalPlayView.contentsCrop` + `customizeDar`.
  MV-HEVC uses AVPlayer + `VideoPlayerComponent`. **MVC (3D Blu-ray) decodes with edge264-mvc**
  into one full side-by-side frame (HANDOFF §5).
- **SMB is not FFmpeg's job any more:** `BassPlayer/NAS/SMBBridge.swift` (AMSMB2/libsmb2 +
  loopback HTTP range server) serves `http://127.0.0.1:<port>/smb/<share>/<path>` to both
  backends. No NFS. ISOs don't play.
- visionOS windows closed with their close button keep their SwiftUI view tree alive and
  deliver no `onDisappear`; `PlaybackController` watches `UIScene.didDisconnectNotification`
  (via `WindowSceneProbe`) and `PlayerScreen` goes inert once its scene disconnects.
- In a `Form`, several plain `Button`s in one row all fire on one tap — one control per row.
- YouTube: `InnerTubeClient.Client.playbackOrder` is the thing to update from yt-dlp when
  playback breaks (`_base.py` clients, `_video.py` `_DEFAULT_JSLESS_CLIENTS`). VISIONOS first,
  IOS fallback; every player call sends a visitor id (`VisitorID`, scraped from the home page),
  without which YouTube bot-checks. FFmpeg gets a local one-variant master
  (`HLSVariantPicker`: no AV1, HDR only if `yt.preferHDR`; `protocol_whitelist` set in
  `FFmpegSession.configure`).
- FFmpeg comes from `Vendor/FFmpegKit`: **stock FFmpegKit 9.0.2 (= FFmpeg 9.0.2)**, its
  xcframeworks (dynamic, embedded in the app — hence the ~20 MB IPA) stripped to visionOS +
  tvOS slices and hosted as release `ffmpegkit-9.0.2-vt1` of this repo by workflow
  `ffmpegkit-repack.yml` (`tools/repack_release.py`; upstream commits the binaries into its git
  tag and has no release assets). `tools/fetch_binaries.sh` downloads + verifies everything in
  CI, including `FFmpegKit-sources.zip` (the C shim target), so `Sources/` is not in git. To
  bump: edit the two tags in the workflow, run it, commit `Package.swift` + `checksums.json` +
  `RELEASE_TAG` from its artifact, fix API fallout in `Vendor/KSPlayer`. The 6.1.4 backport
  pipeline (`ffmpegkit-backports.yml`, `Vendor/FFmpegKit-patches`) is retired; its fixes are
  upstream.
- UI: `RootView` is a `TabView` (`.sidebarAdaptable`) of `AppTab`s; sources are shown by
  `LibraryGridView(source:)` / `YouTubeView` / `NASBrowserView`; everything plays through
  `library.play(item)`, which opens the `PlayerWindow` scene on visionOS and a
  `fullScreenCover` on tvOS. `LibraryStore` has per-source `isSignedIn/isBusy/error/items/
  refresh/status`. Plex connects by probing every address (`connect(to:)`); a host-only SMB
  address lists shares as folders (`NetworkDirectory` treats share/server/workgroup entries
  as directories).
- `MediaItem` is `Codable` (recents); new fields need defaults so the memberwise init stays
  compatible with the four source clients.
- XcodeGen `project.yml` is the source of truth; `BassPlayer.xcodeproj` is generated in CI and
  git-ignored. `.usda` is excluded from the folder source and added as a resource for visionOS.

## Conventions
- Commit messages: imperative summary line; feature branches merged with `--no-ff`.
- Keep the BLE wire protocol in `BassLink.swift`, `BassExtractor.swift` and
  `firmware/.../main.cpp` in sync; bump a version byte if it ever changes.
- Update `docs/SETUP-GUIDE.md` (user-facing) and `docs/HANDOFF.md` (agent-facing) with every
  feature; the owner reads the guide on his phone, so keep steps short.
