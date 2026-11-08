# Handoff — Bass Player

Written 2026-11-08 at the end of the first build session. Everything compiles; nothing has
run on real hardware yet. Your job is to carry it through on-device testing and tuning with
the owner, then whatever comes next.

## 1. The owner and their constraints

- Physician, hobbyist developer, comfortable with Linux, Docker, PlatformIO, OpenWrt.
- Has: Apple Vision Pro, Apple TV 4K, a powered subwoofer, Jellyfin and/or Plex at home,
  Windows PCs with Chrome (Claude in Chrome is connected on two of them), uses Claude on phone.
- **No Mac.** All Swift builds happen in GitHub Actions. Sideloading is wireless with a free
  Apple ID (SideStore/iloader for Vision Pro, atvloadly for Apple TV). Do not propose
  TestFlight, a paid developer account or anything needing Xcode on their desk.
- Is ordering an **ESP32-A1S Audio Kit** (ES8388). Firmware target `esp32-a1s` is the primary
  one; `esp32dev` + PCM5102A is the alternative.
- Prefers blunt, concrete answers; happy to be told "that can't work and here's why".

## 2. What exists

Repo: `muzam2/vision-bass-player` (public). Tag/release creation was not possible from the
original session, so IPAs and firmware are **Actions artifacts** until someone pushes a `v*` tag.

```
project.yml                     XcodeGen spec, two targets: BassPlayer (visionOS 2) and BassPlayerTV (tvOS 17)
BassPlayer/App                  App entry, AVAudioSession, FFmpegConfig.apply(), ImmersiveSpace scene (visionOS)
BassPlayer/Media                MediaItem (server-agnostic item), LibraryStore (source/backend/search settings)
BassPlayer/Jellyfin             JellyfinClient: password auth, movies+episodes, direct + transcode URLs
BassPlayer/Plex                 PlexClient: plex.tv PIN auth, resource discovery, sections, direct-play URLs
BassPlayer/Player               PlayerView (backend switch), FFmpegPlayerView + FFmpegSession, AVPlayer fallback
BassPlayer/Audio                BassExtractor (DSP), BassEngineTap (AVAudioEngine tap + lead delay), BassTapProcessor (MTAudioProcessingTap)
BassPlayer/BLE                  BassLink: CoreBluetooth central, config/status characteristics
BassPlayer/Immersive            visionOS-only RealityKit cinema screen (model, mesh, texture feeder, view, controls)
BassPlayer/Views                ContentView, LibraryView, SettingsView, status ornament
firmware/esp32-bass-receiver    PlatformIO; NimBLE GATT server, jitter buffer, drift control, I²S out, ES8388 init
.github/workflows/build.yml     visionOS + tvOS unsigned IPAs (matrix), SPM cache, FFmpeg link check
.github/workflows/firmware.yml  Both ESP32 envs, uploads .bin + bootloader + partitions
docs/SETUP-GUIDE.md             End-user step-by-step (hardware, flashing, sideloading, servers, tuning)
```

### Data flow
1. Server client builds `MediaItem` with `directURL` (original file) and `avPlayerURL`.
2. `LibraryStore.url(for:)` picks by backend (FFmpeg default).
3. `FFmpegPlayerView` shows `KSVideoPlayerView`; `FFmpegSession` polls for the `KSMEPlayer`,
   attaches `BassEngineTap` to `AudioEnginePlayer.engine.mainMixerNode`.
4. `BassExtractor`: mono or LFE channel → 4th-order Butterworth 120 Hz → decimate to 1 kHz →
   Int16 → 47-byte packets (magic 0xB5, u16 seq, u32 ms, 20 samples).
5. `BassLink.send` → write-without-response to the receiver's audio characteristic.
6. Firmware: ring buffer (target 60 ms + extraDelay), ×8/×16 linear upsample to 8/16 kHz, I²S.
   Two connections allowed; the connection currently sending owns playback (1.5 s idle → takeover).
7. `ImmersiveScreenBridge.shared.frameSource` returns the decoder's current `CVPixelBuffer`;
   `ScreenTextureFeeder` renders it with CoreImage into a RealityKit `DrawableQueue` each frame.

### Settings that exist (all persisted)
Backend, show episodes, Jellyfin creds, Plex token/server, receiver extra delay (0–400 ms,
sent to firmware), bass lead (0–300 ms, FFmpeg only, `bass.leadMs`), mute, immersive width /
distance / height / tilt / yaw / curve / full-immersion / flipV / HDR.

### Dolby Vision (added after the first session)
KSPlayer is now vendored (`Vendor/KSPlayer`) so it could be patched. P8 and P7 play as their
HDR10/HLG base layer. P5 is mapped by `displayDoviNV12Texture` / `displayDoviYUVTexture`
(Shaders.metal) using `DoviMetadata` built from FFmpeg's `AV_FRAME_DATA_DOVI_METADATA`; the
player forces the Metal path (not AVSampleBufferDisplayLayer) for those frames and sets the
layer colour space to ITU‑R 2100 PQ. `DoviFrameRenderer` renders the same mapping into a
texture for the immersive screen. This is the single most likely thing to be visually wrong
on first run (sign of offsets, limited-vs-full range, matrix orientation): compare against
the same film in the Apple TV app and adjust `doviToPQ` in the shader. Reference
implementation: libplacebo `src/shaders/colorspace.c` (`pl_shader_dovi_reshape`,
`pl_shader_decode_color` DOLBYVISION branch).

### 3D (added later)
`StereoFormat` (detection + eye rects + display aspect), `BassPlayerOptions.customizeDar` and
`MetalPlayView.contentsCrop` (vendored) give one-eye display on flat screens without re-decoding.
The cinema screen uses `StereoScreen.usda`, a hand-written MaterialX graph with
`ND_realitykit_cameraindexswitch_color3`; if RealityKit refuses to load it (check the log for
"stereo material unavailable"), rebuild the same graph in Reality Composer Pro on any Mac and
drop the exported `.usda` in — the node ids are the ones RCP exports. MV-HEVC goes through
AVPlayer + `VideoPlayerComponent` (set `ImmersiveScreenBridge.avPlayer`).

### Blu-ray 3D (frame-packed MVC) — not done, two viable routes
MVC = H.264 Annex H: a normal base view plus a *dependent* view predicted from the base view
(inter-view prediction). FFmpeg's h264 decoder drops NAL types 14/15/20, so it yields the
base view only; VideoToolbox has no MVC at all. You cannot rewrite the dependent view into a
standalone H.264 stream (its reference lists point at base-view pictures).

How players like 4XVR do it: a **software MVC decoder**. Open-source options exist:
- **edge264** (BSD-3, C, SIMD incl. NEON) decodes MVC 3D; **edge264-mvc** is a fork hardened
  on complete commercial 3D Blu-rays, multithreaded, portable x86/ARM, with an API that
  returns both views per access unit (`samples` + `samples_mvc`). https://github.com/jens-duttke/edge264-mvc
- **brunoga/mvc** is a pure-Go MVC decoder (bit-exact vs conformance suite) plus `mvctools`
  to convert a 3D Blu-ray/ISO/MKV to side-by-side MKV on Linux. Good for the *offline*
  route; not embeddable in the app.

Route A — convert on the server (works today, zero app changes): `mvctools` (Linux, Go) or
FRIM/BD3D2MK3D (Windows, Intel QuickSync) → half-SBS MKV → plays 3D via the existing path.

Route B — in-app playback (multi-day job, do it on a branch):
1. Add edge264-mvc as a C target in `Vendor/KSPlayer/Package.swift` (it builds for arm64;
   check its NEON path compiles under Xcode's clang; `-O3`, `-march` not needed on Apple).
2. New `Edge264Decode: DecodeProtocol` in `MEPlayer/` chosen by `MEPlayerItemTrack` when the
   H.264 track carries MVC (detect subset SPS NAL 15 / slice-extension NAL 20 in the first
   packets, or FFmpeg's `profile == 128` Stereo High). Feed Annex B (apply `h264_mp4toannexb`
   bsf for MKV/MP4; m2ts is already Annex B). For Blu-ray .m2ts/.ssif the dependent view is
   a second PID (0x1012) that FFmpeg exposes as a second video stream: merge its packets
   into the same access unit before decoding.
3. Output: extend `VideoVTBFrame` with `rightPixelBuffer`; wrap edge264's planar 8-bit
   YUV420 in `kCVPixelFormatType_420YpCbCr8Planar` CVPixelBuffers (copy the planes once).
4. Display: 2D window / tvOS show the base view as now. The immersive screen gets a new
   `ScreenFrame` case carrying two pixel buffers → `ScreenTextureFeeder` renders each into
   its own drawable (the stereo material path already exists). Set `StereoFormat.mvcPacked`
   to mean "true stereo available" once this lands.
5. Performance: 1080p24 × 2 views in software on M2 is fine with edge264's threading; keep
   `hardwareDecode` for everything else.

### YouTube (added later)
`InnerTubeClient` mirrors yt-dlp's client table; `Client.playbackOrder` is the thing to update
when playback breaks (yt-dlp `youtube/_base.py`, INNERTUBE_CLIENTS). The iOS client returns an
HLS manifest (FFmpeg plays it; AVPlayer can too but then the bass tap doesn't work, so the
AVPlayer backend prefers the progressive MP4). `options.userAgent` is set to the issuing
client's UA because googlevideo checks it. SponsorBlock skipping lives in
`FFmpegSession.poll()`; the AVPlayer backend doesn't skip yet. Search parsing walks the whole
JSON for `videoRenderer` so layout changes don't break it.

## 3. Known risks — check these first on hardware

Ordered by likelihood of needing a fix.

0. **Dolby Vision P5 colours wrong** — see the section above; everything else about DV
   (detection, pipeline selection, texture feed) is plumbing that compiles and is simple.
0b. **YouTube playback stops working** — client identities out of date (see above). Also
    possible: HLS from the iOS client needs the `X-Goog-Visitor-Id`/PO token in future; yt-dlp
    will show the current recipe.
0c. **Stereo material fails to load** — see the 3D section; fallback is left-eye-only.
1. **Tap never installs on visionOS/tvOS.** `FFmpegSession.poll()` requires
   `engine.mainMixerNode.outputFormat(forBus:0).sampleRate > 0`. If the chip stays "Bass tap
   off" while audio plays, log the format and the `layer.state` sequence; possibly KSPlayer's
   AudioEnginePlayer isn't the chosen `audioOutput` on that platform (check
   `KSOptions.audioPlayerType` took effect; tvOS may prefer `AudioRendererPlayer` for passthrough).
2. **Lead delay rewiring** (`BassEngineTap.applyLead`) disconnects/reconnects the mixer at
   runtime. If it glitches or silences audio, simplest fallback: keep `videoDelay` only and
   accept the headset audio leading the sub; or re-create the delay before `engine.start()` by
   hooking earlier in the state sequence.
3. **Immersive texture orientation / colour.** Vertical flip is a toggle. HDR path uses
   `rgba16Float` drawables + extended linear Display P3; if washed out, try rendering with
   `CGColorSpace.itur_2100_PQ` / HLG matching the buffer's transfer function, or drop to
   8-bit sRGB (toggle exists).
4. **Plex connection choice.** `discoverServers` prefers `local && !relay`. Remote-only users
   get a relay URL (slow). Expose the connection list in Settings if needed.
5. **Jellyfin transcode URL** (`stream.mp4?static=false`) is only for the AVPlayer fallback and
   is unverified; the FFmpeg path uses `static=true`, which is standard.
6. **Firmware drift control** nudges one sample per second when off-target by >15. If the
   buffer drifts faster than that, scale the correction with the error.
7. **A1S line out level.** Headphone-level output may clip some sub inputs. Lower registers
   0x2E–0x31 (LOUT/ROUT volume, 0x1E ≈ 0 dB; each step ≈ 1.5 dB) in `codecInit()`.
8. **AC101 variant** of the A1S is unsupported (serial prints `ES8388 init FAILED`).
9. **BLE throughput on Apple TV** is untested; same code path as visionOS.
10. **Free-ID signing**: CoreBluetooth needs no entitlement, but if SideStore strips
    `NSBluetoothAlwaysUsageDescription` the permission prompt won't show. Verify after install.

## 4. How to work on it

- Branch → `gh workflow run build.yml --ref <branch>` → poll every 30 s → fix → merge
  `--no-ff` into `main`. Firmware changes trigger `firmware.yml` on `main`; for a branch, use
  `gh workflow run firmware.yml --ref <branch>`.
- Failed job errors: `gh run view <id> --log-failed | grep "error:"`. The build step greps the
  xcodebuild output for `error:` and `BUILD` so the Actions UI shows only what matters; the
  full log is uploaded as an artifact on failure.
- KSPlayer source is worth cloning locally (`--branch GPLv3`) to read APIs before guessing;
  useful files: `Sources/KSPlayer/AVPlayer/KSOptions.swift`, `MEPlayer/AudioEnginePlayer.swift`,
  `MEPlayer/KSMEPlayer.swift`, `AVPlayer/KSVideoPlayer.swift`, `SwiftUI/KSVideoPlayerView.swift`.
- Firmware can be built locally with PlatformIO if the registry is reachable; otherwise CI.

## 5. Suggested next steps, in order

1. **First-run support.** Owner flashes the A1S, installs the visionOS IPA, reports the status
   chip and serial log. Fix whatever breaks in §3 items 1–2 first.
2. **Timing tune.** Add a one-tap "measure latency" that sends a tagged click and reads the
   receiver's played-timestamp back over the status characteristic (firmware: record
   `millis()` when the marker sample reaches the DAC). Auto-set `bass.leadMs`.
3. **Immersive polish.** Hide the 2D window while the immersive screen is open (or shrink it
   to a control strip); add play/pause/seek via a small attachment on the screen; per-film
   remembered placement is probably overkill.
4. **Library UX.** Group episodes by series; "continue watching" from Jellyfin/Plex resume
   points; poster grid instead of list on visionOS.
5. **Firmware extras.** Optional Wi‑Fi (UDP) transport for higher-rate bass (2–4 kHz) and
   lower latency; OTA updates so the owner never re-plugs the board.
6. **Release hygiene.** Owner pushes `v0.2.0`; both workflows attach artifacts to the release.

## 6. Things deliberately not done

- No in-app MVC decoding yet (see the Blu-ray 3D section; owner knows both routes).
- No KSPlayer-based player for DRM services (impossible in-sandbox; told the owner).
- No system-wide audio capture (visionOS has no third-party audio driver layer; told the owner).
- No Plex transcoding for the AVPlayer fallback (FFmpeg backend makes it unnecessary).
- No paid-account features (push-to-TestFlight, App Store).
