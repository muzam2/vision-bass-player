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
2026-11-08 and iterated all day with a live log stream. The ESP32-A1S receiver arrived
2026-11-20 (`docs/RECEIVER-BRINGUP.md`, `tools/receiver_test.py`). Since the night of
2026-11-20 the headset drives it: the owner hears bass, 60 fps video plays in a window with
no dropped frames, and a YouTube connection reset recovers by itself (HANDOFF §0, "Headset
results"). Read the `render:` and `bass` lines in the live log before changing playback code.

## Build & verify
- Never try to build Swift locally; push and read Actions. `build.yml` (visionOS + tvOS unsigned
  IPAs) runs on pushes to `main`, PRs, `v*` tags and `workflow_dispatch`. `firmware.yml` builds
  both ESP32 targets when `firmware/**` changes.
- Feature work goes on a branch; trigger it with `gh workflow run build.yml --ref <branch>`,
  then merge `--no-ff` to `main` once both jobs are green.
- When polling Actions, wait 30 s between checks, not 10.
- Compile errors: `gh run view <id> --log-failed | grep "error:"`. Expect Xcode 26 / visionOS
  SDK on `macos-15` + `setup-xcode@latest-stable`.
- The IPA packaging step prints app size, `FFmpeg: linked`, the `FFmpeg version` string of the
  embedded Libavutil and one `embedded: X` line per
  dynamic framework the binary loads; it **fails** if a loaded framework is missing from
  `Frameworks/` (a dynamic SwiftPM product that the generated project did not embed = dyld
  crash at launch; that is why AMSMB2 is vendored as a static library).
- **Look at the UI before shipping it:** `gh workflow run ui-screenshots.yml --ref <branch>`
  builds for the visionOS + tvOS simulators and uploads a PNG per tab (demo data via
  `BASSPLAYER_DEMO=1`, tab via `BASSPLAYER_SCREEN`). Download the `screenshots-*` artifacts and
  read the images. New screens should be added to `DemoData` and the workflow's screen list.
- A `v*` tag makes a GitHub release with both IPAs and the firmware binaries attached
  (`build.yml` and `firmware.yml`); `v0.2.0` (2026-11-21) is the first. The README and the
  setup guide send visitors to the latest release, so tag again when a build worth installing
  lands, and attach the calibration videos (`tools/make_bass_sync_videos.py`).
- `Vendor/FFmpegKit/tools/fetch_binaries.sh` always downloads from `muzam2/vision-bass-player`
  (override: `FFMPEGKIT_RELEASE_REPO`), because forks have no releases.

## Hard-won facts (don't rediscover)
- KSPlayer is **vendored** at `Vendor/KSPlayer` (from the `GPLv3` branch; upstream `main`
  now ships a binary xcframework, so its FFmpeg-facing code is no longer available as source
  — our copy is the source of truth) and patched for Dolby Vision P5, one-eye crop, a frame
  sink for the cinema screen, FFmpeg 9 API, the MVC decoder (`MEPlayer/Edge264Decode.swift`)
  and a few lifecycle fixes (`keepsPlayerWhenViewGoesAway`, no player resurrection in
  `updateUIView`, display link at panel rate on visionOS, timestamped presentation).
  Patched files: HANDOFF §3.
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
- FFmpeg comes from `Vendor/FFmpegKit`: **FFmpeg n9.1 + FFmpegKit's 13 FFmpeg patches, compiled
  by our own workflow** (kingslay/FFmpegKit has no 9.1 tag and no public build plugin any
  more). `ffmpegkit-build.yml` builds the five slices (visionOS + tvOS, device + simulator)
  with the configure line recovered from the 9.0.2 binaries, the patches in
  `Vendor/FFmpegKit/ffmpeg-build/patches` (ten are FFmpegKit's files unchanged, three re-made
  for n9.1, see the README there; a patch that does not apply fails the build) and the Vulkan
  headers of FFmpegKit's MoltenVK, checks the result against the 9.0.2 libraries (configure
  line, version strings, load commands, components) and publishes release `ffmpegkit-9.1-vt1`.
  Only the seven `Lib*` xcframeworks are ours; the other 15 (dependencies; the dynamic ones are
  embedded in the app, hence the ~20 MB IPA) and `FFmpegKit-sources.zip` (the C shim target)
  are byte-identical to `ffmpegkit-9.0.2-vt1`, the stock FFmpegKit 9.0.2 repack
  (`ffmpegkit-repack.yml`, `tools/repack_release.py`). `tools/fetch_binaries.sh` downloads +
  verifies everything in CI, so `Sources/` is not in git. **"Stock FFmpeg 9.0.2" in older notes
  means n9.0.2 plus those same 13 FFmpegKit patches, never plain FFmpeg.** To rebuild or bump:
  HANDOFF §3 "FFmpeg 9.1" (never overwrite a release, bump the `-vtN` suffix; commit
  `Package.swift` + `checksums.json` + `RELEASE_TAG` from the publishing run's artifact; fix API
  fallout in `Vendor/KSPlayer`). The 6.1.4 backport pipeline (`ffmpegkit-backports.yml`,
  `Vendor/FFmpegKit-patches`) is retired; its fixes are upstream.
- UI: `RootView` is a `TabView` (`.sidebarAdaptable`) of `AppTab`s; sources are shown by
  `LibraryGridView(source:)` / `YouTubeView` / `NASBrowserView`; everything plays through
  `library.play(item)`, which opens the `PlayerWindow` scene on visionOS and a
  `fullScreenCover` on tvOS. `LibraryStore` has per-source `isSignedIn/isBusy/error/items/
  refresh/status`. Plex connects by probing every address (`connect(to:)`); a host-only SMB
  address lists shares as folders (`NetworkDirectory` treats share/server/workgroup entries
  as directories).
- `MediaItem` is `Codable` (recents); new fields need defaults so the memberwise init stays
  compatible with the four source clients.
- Firmware: Arduino core 3.3+ (PlatformIO `espressif32` 8.x) frees the BT controller memory
  at start-up unless a BLE library registers via `esp32-hal-alloc-ble-mem.h`. NimBLE-Arduino
  1.4.x doesn't, so `main.cpp` includes that header; removing it brings back a boot loop in
  `NimBLEDevice::init` (`esp_bt_controller_init` → `ESP_ERR_INVALID_STATE`). Firmware bugs
  like this only show on the board, never in CI. `platformio.ini` pins the board-tested pair
  (espressif32 8.0.0, NimBLE-Arduino 1.4.3); bump one at a time and test on hardware.
- FFmpeg's HLS demuxer does not pass `formatContextOptions` on to its segment connections;
  HTTP options for segments go through `KSOptions.reconnectNestedHTTP` (an `io_open` wrapper
  in `MEPlayerItem`). A segment read error is silently treated as end of segment, which
  corrupts fMP4 parsing; `FFmpegSession.watchForVideoStall` is the safety net for YouTube.
- Judder is main-thread starvation, not decoding: `MetalPlayView`'s display link runs on the
  main run loop and shows one frame per tick, so anything that redraws SwiftUI at a steady
  rate (a `@Published` assigned on a timer, even with an unchanged value) drops frames on
  60 fps video. Fast-changing values get their own small `ObservableObject` observed by a leaf
  view (`BassMeter`/`BassTapLabel`). The `render:` log line every 10 s is the measurement.
- Timestamped frame pacing (2026-11-21, Settings → Diagnostics, off by default, **not yet
  proven on the headset**): `MetalPlayView.requestedPresentationMode = .timestamped` makes a
  pump on its own queue enqueue frames up to 150 ms ahead with their media timestamps on the
  display layer's renderer, under a control timebase that follows the audio clock
  (`MEPlayer/TimestampedVideoPresenter.swift`). The display-link loop stays the default and
  the fallback for the cinema screen (`frameSink` is only called by the loop), Dolby Vision
  P5 and 10-bit software frames. The pump must never read state the main thread updates:
  the audio clock comes from readings `MEPlayerItem.setAudio` stores on the audio render
  thread. `render:` lines start with `mode display-link` or `mode timestamped`. The stall
  test switch blocks the main thread on purpose and is never persisted. HANDOFF §0 has the
  acceptance test.
- The renderer calls the pump uses (`enqueue`, `isReadyForMoreMediaData`, `flush`, `status`)
  are deprecated from OS 27.0 for `AVSampleBufferVideoRenderer.Receiver` (27.0+ only, through
  a render synchronizer). At deployment targets 26.0 / 18.0 they are correct and warning-free.
- BLE sending: the engine tap delivers 100 ms buffers, i.e. five bass packets at once, and
  CoreBluetooth accepts one write-without-response per turn of its delegate queue. `BassLink`
  therefore queues packets and paces them out every 20 ms; sending a burst directly loses four
  packets in five ("sent N dropped 4N" in the log, no audible bass).
- Seeking: `AsyncPlayerItemTrack.seek` empties the packet queue (which wakes the decode thread)
  before it sets `state = .flush`, so the thread can be back in `pop` with the flush pending and
  upstream then threw away the next packet: the keyframe of the new position. Every frame up to
  the next keyframe failed ("Not all references are available"), the picture froze until the
  stall watchdog reopened the stream; about three seeks in ten with FFmpeg 9.1, none seen with
  9.0.2 (same code, different timing). The thread now flushes and keeps that packet; packets
  carry a seek epoch so leftovers are still dropped. Log line: "[seek] first packet arrived with
  a flush pending".
- KSPlayer's Metal path (10-bit software frames such as YouTube VP9 HDR, Dolby Vision P5) must
  load the package's shader library, not the main bundle's: the app has its own
  `Immersive/FrameConvert.metal`, so `makeDefaultLibrary()` returns a library without KSPlayer's
  functions and pipeline creation aborts the app (`MetalRender.library`). `CrashCapture` also
  keeps standard error, where Metal and Swift print the reason for an abort.
- XcodeGen `project.yml` is the source of truth; `BassPlayer.xcodeproj` is generated in CI and
  git-ignored. `.usda` is excluded from the folder source and added as a resource for visionOS.

- PlayStation Remote Play (`BassPlayer/RemotePlay`, `Vendor/ChiakiCore`): chiaki-ng core,
  local network only, no PSN code at all (stubs). Consoles are added by IP (visionOS blocks
  broadcast discovery without the multicast entitlement). Never hand-edit
  `Vendor/ChiakiCore/vendor/`; re-run `tools/vendor_chiaki.sh`. OpenSSL/Opus headers come from
  FFmpegKit's framework slices via `-I` in its Package.swift. HANDOFF §0 has the design.

## Conventions
- Commit messages: imperative summary line; feature branches merged with `--no-ff`.
- Keep the BLE wire protocol in `BassLink.swift`, `BassExtractor.swift` and
  `firmware/.../main.cpp` in sync; bump a version byte if it ever changes.
- Update `docs/SETUP-GUIDE.md` (user-facing) and `docs/HANDOFF.md` (agent-facing) with every
  feature; the owner reads the guide on his phone, so keep steps short.
