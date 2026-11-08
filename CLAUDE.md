# Bass Player — notes for Claude Code

Read `docs/HANDOFF.md` first: it has the full state, decisions, open risks and the next-step
list. This file is the short version.

## What this is
visionOS + tvOS video player (SwiftUI, vendored KSPlayer/FFmpeg) that streams sub-bass over
BLE to an ESP32 receiver wired to a powered subwoofer. Sources: Jellyfin, Plex, YouTube
(InnerTube), NAS (SMB/WebDAV). Vision Pro gets a RealityKit cinema screen with 3D and VR.
Owner has **no Mac**: everything is compiled by GitHub Actions and sideloaded with a free
Apple ID. Nothing has run on hardware yet.

## Build & verify
- Never try to build Swift locally; push and read Actions. `build.yml` (visionOS + tvOS unsigned
  IPAs) runs on pushes to `main`, PRs, `v*` tags and `workflow_dispatch`. `firmware.yml` builds
  both ESP32 targets when `firmware/**` changes.
- Feature work goes on a branch; trigger it with `gh workflow run build.yml --ref <branch>`,
  then merge `--no-ff` to `main` once both jobs are green.
- When polling Actions, wait 30 s between checks, not 10.
- Compile errors: `gh run view <id> --log-failed | grep "error:"`. Expect Xcode 26 / visionOS
  SDK on `macos-15` + `setup-xcode@latest-stable`.
- The IPA packaging step prints app size and `FFmpeg: linked`; check it after any change to
  `project.yml` or `Vendor/KSPlayer`.
- Tag pushes and release creation were blocked for the original agent session; the owner can
  push a `v*` tag himself to get a GitHub release with IPAs + firmware attached.

## Hard-won facts (don't rediscover)
- KSPlayer is **vendored** at `Vendor/KSPlayer` (from the `GPLv3` branch; upstream `main`
  ships a binary xcframework with no xros slice) and patched for Dolby Vision P5, one-eye
  crop, SMB listing and a public frame renderer. Patched files are listed in HANDOFF §3; diff
  against `UPSTREAM_COMMIT` when pulling upstream.
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
- The immersive-space origin is on the **floor**; screen `height` is absolute metres. Recentre
  uses ARKit `WorldTrackingProvider.queryDeviceAnchor` (no permission prompt).
- Packed 3D: flat displays crop one eye with `MetalPlayView.contentsCrop` + `customizeDar`;
  the cinema screen binds left/right textures to `StereoScreen.usda` (hand-written MaterialX
  graph, Camera Index Switch). MV-HEVC uses AVPlayer + `VideoPlayerComponent`. MVC (Blu-ray
  3D) is base-view-only until edge264-mvc is integrated (plan in HANDOFF §5).
- FFmpegKit already links **libsmbclient**: `smb://user:pass@host/share/file` plays and
  `NetworkDirectory.list` (avio_open_dir) browses. No NFS. ISOs don't play.
- YouTube: `InnerTubeClient.Client.playbackOrder` is the thing to update from yt-dlp when
  playback breaks (`_base.py` clients, `_video.py` `_DEFAULT_JSLESS_CLIENTS`). VISIONOS first,
  IOS fallback; every player call sends a visitor id (`VisitorID`, scraped from the home page),
  without which YouTube bot-checks. FFmpeg gets a local one-variant master
  (`HLSVariantPicker`, SDR only, `protocol_whitelist` set in `FFmpegSession.configure`).
- FFmpegKit 6.1.4 is stock FFmpeg 6.1 (no patches): it rejects init segments with both
  `mdcv` + `SmDm` (YouTube HDR; fixed in 7.1) and loses video after any seek in fMP4 HLS
  (`mov_read_packet` doesn't reset its fragment index on HLS seek; fixed in 8.1). YouTube
  resume is disabled for that reason. FFmpegKit 9.x has the fixes but drops libsmbclient.
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
