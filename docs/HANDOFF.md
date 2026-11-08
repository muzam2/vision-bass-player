# Handoff — Bass Player

Last updated 2026-11-08, end of the first build session (v0.2.x on `main`). Everything
compiles for visionOS and tvOS; **nothing has run on real hardware yet**. Your job is to carry
it through on-device testing and tuning with the owner, then whatever comes next.

## 1. The owner and their constraints

- Physician, hobbyist developer, comfortable with Linux, Docker, PlatformIO, OpenWrt.
- Has: Apple Vision Pro, Apple TV 4K, a powered subwoofer, Jellyfin and/or Plex and a NAS at
  home, Windows PCs with Chrome (Claude in Chrome is connected on two of them), uses Claude
  mostly on the phone.
- **No Mac.** All Swift builds happen in GitHub Actions. Sideloading is wireless with a free
  Apple ID (SideStore/iloader for Vision Pro, atvloadly for Apple TV). Do not propose
  TestFlight, a paid developer account or anything needing Xcode on their desk.
- Is ordering an **ESP32-A1S Audio Kit** (ES8388). Firmware target `esp32-a1s` is primary;
  `esp32dev` + PCM5102A is the alternative.
- Prefers blunt, concrete answers; happy to be told "that can't work and here's why". Asks
  "why not X?" and expects a real reason; correct yourself openly if you were wrong (that
  happened once with MVC, see §4).

## 2. What exists

Repo: `muzam2/vision-bass-player` (public). Tag/release creation was not possible from the
original session, so IPAs and firmware are **Actions artifacts** until someone pushes a `v*` tag.

```
project.yml                     XcodeGen spec: BassPlayer (visionOS 2) + BassPlayerTV (tvOS 17), same sources, KSPlayer from Vendor/
Vendor/KSPlayer                 KSPlayer GPLv3 source, vendored + patched (see §3). UPSTREAM_COMMIT = base commit
BassPlayer/App                  App entry, AVAudioSession, FFmpegConfig.apply(), ImmersiveSpace scene (visionOS)
BassPlayer/Media                MediaItem (server-agnostic, Codable), MediaSource, StereoFormat, ScreenProjection, LibraryStore (settings, overrides, recents, progress)
BassPlayer/Jellyfin             Password auth, movies+episodes, direct/transcode URLs, external subs, resume, progress reporting
BassPlayer/Plex                 plex.tv PIN auth, resource discovery, per-server token, direct-play, external subs, resume, timeline reporting
BassPlayer/YouTube              InnerTubeClient (search/trending/player with client fallbacks), SponsorBlockClient, YouTubeClient
BassPlayer/NAS                  NASClient (SMB via FFmpeg avio, WebDAV PROPFIND + HTML index), Keychain, NASBrowserView
BassPlayer/Player               PlayerView (resolve → backend switch, 3D/projection pickers), FFmpegPlayerView + FFmpegSession, AVPlayer fallback
BassPlayer/Audio                BassExtractor (DSP), BassEngineTap (AVAudioEngine tap + lead delay), BassTapProcessor (MTAudioProcessingTap)
BassPlayer/BLE                  BassLink: CoreBluetooth central, config/status characteristics
BassPlayer/Immersive            visionOS-only: model, flat/curved/VR meshes, ScreenTextureFeeder, ImmersiveScreenView, StereoScreen.usda
BassPlayer/Views                ContentView, LibraryView (source picker, recents), SettingsView, status ornament
firmware/esp32-bass-receiver    PlatformIO; NimBLE GATT server, 2-device arbitration, jitter buffer, drift control, I²S, ES8388 init
.github/workflows/build.yml     visionOS + tvOS unsigned IPAs (matrix), SPM cache, "FFmpeg: linked" check
.github/workflows/firmware.yml  Both ESP32 envs, uploads .bin + bootloader + partitions
docs/SETUP-GUIDE.md             End-user step-by-step (hardware, flashing, sideloading, sources, tuning)
```

### Data flow
1. A source client builds `MediaItem`s: `directURL` (original file; FFmpeg), `avPlayerURL`,
   detected `stereo` / `projection`, `subtitleURLs`, `serverResumeSeconds`. YouTube items
   have `needsResolve = true`; `LibraryStore.resolve` fetches fresh stream URLs at play time.
2. `LibraryStore.effectiveBackend(for:)`: FFmpeg by default; AVPlayer for MV-HEVC; FFmpeg
   forced for NAS. `url(for:)` picks accordingly.
3. `FFmpegPlayerView` shows `KSVideoPlayerView`; `FFmpegSession` polls every 0.5 s for the
   `KSMEPlayer`, attaches `BassEngineTap` to `AudioEnginePlayer.engine.mainMixerNode`, applies
   the one-eye crop, tracks progress, skips SponsorBlock segments, fires the sleep timer and
   reports `finished` for autoplay.
4. `BassExtractor`: mono or LFE channel → 4th-order Butterworth 120 Hz → decimate to 1 kHz →
   Int16 → 47-byte packets (magic 0xB5, u16 seq, u32 ms, 20 samples) → `BassLink.send`.
5. Firmware: ring buffer (target 60 ms + extraDelay), ×8/×16 linear upsample, I²S. Two
   connections allowed; the connection currently sending owns playback (1.5 s idle → takeover).
6. `ImmersiveScreenBridge.shared` carries `frameSource` (ScreenFrame = pixel buffer or
   pre-mapped DV texture), `stereoFormat`, `projection`, `avPlayer`. `ScreenTextureFeeder`
   renders with CoreImage (picture controls applied) into one or two RealityKit
   `DrawableQueue`s; the view binds them to an `UnlitMaterial` or the stereo
   `ShaderGraphMaterial`, on a flat/curved/VR mesh; MV-HEVC uses `VideoPlayerComponent`.

### Persisted settings
Backend, show episodes, resume, autoplay next, Jellyfin creds, Plex token/server/server-token,
NAS shares (+Keychain passwords), YouTube SponsorBlock, receiver extra delay (0–400 ms, sent
to firmware), bass lead (0–300 ms, FFmpeg only, `bass.leadMs`), mute, per-item stereo and
projection overrides (`stereo.<id>`, `proj.<id>`), positions (`pos.<id>`), recents, immersive
width / distance / height (absolute metres above floor) / tilt / yaw / curve / full-immersion /
room dim / flipV / HDR / brightness / contrast / saturation / HDR boost.

## 3. Vendored KSPlayer patches (keep when pulling upstream)

- `MEPlayer/DoviMetadata.swift` — Dolby Vision RPU → flat float array (reshaping curves,
  matrices); built in `FFmpegDecode` from `AV_FRAME_DATA_DOVI_METADATA`; attached to
  `VideoVTBFrame.dovi`.
- `Metal/Shaders.metal` — `displayDoviNV12Texture` / `displayDoviYUVTexture` (profile 5
  mapping, output PQ BT.2020). `Metal/DisplayModel.swift` + `Metal/MetalRender.swift` select
  them and pass the metadata (`setFragmentBytes`, index 3). `MetalRender.render(into:)` and
  `Metal/DoviFrameRenderer.swift` expose the mapping for the immersive screen.
- `MEPlayer/MetalPlayView.swift` — forces the Metal path for P5 frames, PQ colour space,
  `currentFrame` (public), `contentsCrop` (one-eye display for packed 3D).
- `MEPlayer/NetworkDirectory.swift` — `avio_open_dir` wrapper for SMB listing.
- `Package.swift` — tests removed, otherwise upstream.

Dolby Vision P5 needs `KSOptions.asynchronousDecompression = false` (FFmpeg hwaccel path) so
the RPU side data reaches the frame. P7/P8 bypass the mapping (HDR10/HLG base layer).

## 4. Known risks — check these first on hardware

Ordered by likelihood of needing a fix.

1. **Dolby Vision P5 colours wrong** — sign of offsets, limited-vs-full range, matrix
   orientation in `doviToPQ`. Compare with the Apple TV app on the same film. Reference:
   libplacebo `src/shaders/colorspace.c` (`pl_shader_dovi_reshape`, DOLBYVISION branch).
2. **Bass tap never installs.** `FFmpegSession.poll()` needs
   `engine.mainMixerNode.outputFormat(forBus:0).sampleRate > 0`. If the chip stays "Bass tap
   off", log the format and `layer.state`; check `KSOptions.audioPlayerType` took effect
   (tvOS may prefer `AudioRendererPlayer`).
3. **Lead delay rewiring** (`BassEngineTap.applyLead`) reconnects the mixer at runtime. If it
   glitches: keep `videoDelay` only, or insert the delay before `engine.start()`.
4. **Stereo material fails to load** (`StereoScreen.usda`, hand-written MaterialX with
   `ND_realitykit_cameraindexswitch_color3`). Log says "stereo material unavailable";
   fallback is left-eye-only. Fix: rebuild the same graph in Reality Composer Pro on any Mac
   and drop in its exported `.usda`.
5. **Immersive orientation / colour.** Vertical flip is a toggle. VR sphere may be mirrored
   left-right (negate `x` in `ScreenMesh.makeVR`). HDR path uses rgba16Float + extended
   linear Display P3; if washed out, match the buffer's transfer function or use the 8-bit toggle.
6. **Inverted 3D depth** on some rips (right-eye-first): add a left/right swap toggle (swap
   the two eye rects in `StereoFormat`).
7. **YouTube stops playing** — client identities out of date. Update `Client.playbackOrder`
   in `InnerTubeClient.swift` from yt-dlp `youtube/_base.py` (INNERTUBE_CLIENTS). HLS from the
   iOS client may start needing a PO token. Resume via `startPlayTime` on HLS is untested.
8. **SMB against SMB3-only NAS** — libsmbclient should negotiate; options go through
   `NetworkDirectory.list(options:)`. Guest access with empty username on Windows untested.
9. **Plex connection choice** prefers `local && !relay`; remote-only users get a relay (slow).
10. **Firmware drift control** nudges one sample per second when off by >15; scale with error
    if the buffer still drifts. **A1S line-out level** may clip some subs: lower registers
    0x2E–0x31 in `codecInit()` (0x1E ≈ 0 dB, ~1.5 dB per step). **AC101 variant** unsupported.
11. **Free-ID signing**: verify the Bluetooth and Local Network prompts appear after sideloading.

## 5. Not done, and why

- **Blu-ray 3D (frame-packed MVC).** FFmpeg decodes only the base view; VideoToolbox has no
  MVC. It *is* doable in software: **edge264-mvc** (BSD-3, C, NEON, both views per access
  unit, https://github.com/jens-duttke/edge264-mvc) is what players like 4XVR effectively do.
  Plan: add it as a C target in `Vendor/KSPlayer/Package.swift`; new `Edge264Decode:
  DecodeProtocol` chosen when the H.264 track is Stereo High (profile 128 / NAL 15/20
  present); feed Annex B (bsf `h264_mp4toannexb` for MKV/MP4; merge the 0x1012 PID stream for
  m2ts/ssif); extend `VideoVTBFrame` with `rightPixelBuffer` (420YpCbCr8Planar); new
  `ScreenFrame` case with two buffers → feeder → existing stereo material. Owner agreed this
  can wait. Offline alternative today: `mvctools` (https://github.com/brunoga/bdtools, Linux)
  or BD3D2MK3D/FRIM (Windows + Intel GPU) → half-SBS MKV.
- **DRM services (Netflix etc.).** Not possible and not to be attempted: streams are
  encrypted and keys only reach Apple's own pipeline; impersonating the client would mean DRM
  circumvention. Owner asked theoretically and accepted the answer.
- **System-wide audio capture** — visionOS has no third-party audio driver layer.
- **DLNA/UPnP, cloud drives, 3D theatre environments, 2D-window picture controls**
  (hardware frames would need `hwdownload`), **Plex transcoding for the AVPlayer fallback**.
- **Paid-account features** (TestFlight, App Store).

## 6. How to work on it

- Branch → `gh workflow run build.yml --ref <branch>` → poll every 30 s → fix → merge
  `--no-ff` into `main`. Firmware changes trigger `firmware.yml` on `main`; for a branch, use
  `gh workflow run firmware.yml --ref <branch>`.
- Failed job errors: `gh run view <id> --log-failed | grep "error:"`. The build step greps the
  xcodebuild output so the Actions UI shows only `error:` and `BUILD` lines; the full log is
  uploaded as an artifact on failure.
- The vendored KSPlayer is the place to read APIs before guessing; useful files:
  `AVPlayer/KSOptions.swift`, `MEPlayer/AudioEnginePlayer.swift`, `MEPlayer/KSMEPlayer.swift`,
  `AVPlayer/KSVideoPlayer.swift`, `SwiftUI/KSVideoPlayerView.swift`, `MEPlayer/MetalPlayView.swift`.
- Firmware can be built locally with PlatformIO if the registry is reachable; otherwise CI.

## 7. Suggested next steps, in order

1. **First-run support.** Owner flashes the A1S, installs the visionOS IPA, reports the status
   chip and serial log. Work down §4.
2. **Timing tune.** One-tap "measure latency": send a tagged click, read the receiver's
   played-timestamp back over the status characteristic, auto-set `bass.leadMs`.
3. **Immersive polish.** Hide/shrink the 2D window while the cinema screen is open; a small
   play/pause/seek attachment on the screen; left/right swap toggle.
4. **MVC via edge264-mvc** (§5) once a test file is on the owner's server.
5. **Library UX.** Group episodes by series; poster grid on visionOS.
6. **Firmware extras.** Optional Wi‑Fi (UDP) transport for higher-rate bass and lower latency;
   OTA updates.
7. **Release hygiene.** Owner pushes `v0.3.0`; both workflows attach artifacts to the release.
