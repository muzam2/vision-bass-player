# Bass Player — notes for Claude Code

Read `docs/HANDOFF.md` first: it has the full state, decisions, open risks and the next-step
list. This file is the short version.

## What this is
visionOS + tvOS video player (SwiftUI, KSPlayer/FFmpeg) that streams sub-bass over BLE to an
ESP32 receiver wired to a powered subwoofer. Owner has **no Mac**: everything is compiled by
GitHub Actions and sideloaded with a free Apple ID.

## Build & verify
- Never try to build Swift locally; push and read Actions. `build.yml` (visionOS + tvOS unsigned
  IPAs) runs on pushes to `main`, PRs, `v*` tags and `workflow_dispatch`. `firmware.yml` builds
  both ESP32 targets when `firmware/**` changes.
- Feature work goes on a branch; trigger it with `gh workflow run build.yml --ref <branch>`,
  then merge to `main` once both jobs are green.
- When polling Actions, wait 30 s between checks, not 10.
- Compile errors: `gh run view <id> --log-failed | grep "error:"`. Expect Xcode 26 / visionOS
  SDK on `macos-15` + `setup-xcode@latest-stable`.
- The IPA packaging step prints app size and `FFmpeg: linked` — check it after any change to
  `project.yml` or the KSPlayer dependency.

## Hard-won facts (don't rediscover)
- KSPlayer: use the **`GPLv3` branch** (full source, visionOS). `main` ships a binary
  xcframework with no xros slice.
- `KSVideoPlayerView` overwrites `coordinator.onStateChanged`; `FFmpegSession` therefore polls
  `coordinator.playerLayer` every 0.5 s to find the `KSMEPlayer`, its `AudioEnginePlayer.engine`
  and `videoOutput.pixelBuffer`.
- `AudioEnginePlayer` is `public` not `open`: tap `engine.mainMixerNode` from outside; don't
  subclass. Lead compensation rewires mixer → `AVAudioUnitDelay` → output and sets
  `options.videoDelay`.
- `MTAudioProcessingTapCreate` returns `MTAudioProcessingTap?` directly in the Xcode 26 SDK.
- `@AppStorage` inside an `ObservableObject` doesn't publish; use `@Published` + `UserDefaults`.
- tvOS has no `Stepper`, `.ornament`, `.glassBackgroundEffect`, `.searchable` quirks: guard
  with `#if os(visionOS)` / `#if os(tvOS)`. All immersive code is `#if os(visionOS)`.
- XcodeGen `project.yml` is the source of truth; `BassPlayer.xcodeproj` is generated in CI and
  git-ignored. Both targets compile the same `BassPlayer/` sources.

## Conventions
- Commit messages: imperative summary line; feature branches merged with `--no-ff`.
- Keep the BLE wire protocol in `BassLink.swift`, `BassExtractor.swift` and
  `firmware/.../main.cpp` in sync; bump a version byte if it ever changes.
- Don't add telemetry, accounts or anything that needs a paid developer account.
