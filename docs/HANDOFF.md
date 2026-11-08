# Handoff — Bass Player

Last updated 2026-11-08 (v0.2.x on `main`). Compiles for visionOS and tvOS. **Installed on the
owner's Vision Pro on 2026-11-08** (see §1 for the sideloading route). First run found three
breakages, all fixed on `main` the same day: Plex ("server with the specified host name could
not be found" = the home router's DNS-rebinding protection refusing `*.plex.direct`; app now
probes every address incl. a plain `http://IP:port` twin, and the router got a `plex.direct`
exception), NAS (a host-only SMB address listed nothing: shares came back as their own entry
type and were filtered as non-video files), YouTube ("unexpected response": the anonymous
Trending page is gone, and the search box only existed once a list had items). The UI was then
rebuilt around tabs (§2). The ESP32 board hasn't arrived; nothing has reached the sub yet.

## 1. The owner and their constraints

- Physician, hobbyist developer, comfortable with Linux, Docker, PlatformIO, OpenWrt.
- Has: Apple Vision Pro, Apple TV 4K, a powered subwoofer, Jellyfin and/or Plex and a NAS at
  home, Windows PCs with Chrome (Claude in Chrome is connected on two of them), uses Claude
  mostly on the phone.
- **No Mac.** All Swift builds happen in GitHub Actions. Sideloading is wireless with a free
  Apple ID. Do not propose TestFlight, a paid developer account or anything needing Xcode on
  their desk.
  **Vision Pro route that actually works (2026-11-08):** stock iloader can't see a Vision Pro
  (usbmuxd only). rebelancap's `visionos-tunnel` fork can (mDNS + RemotePairing tunnel) but its
  old sign-in library (isideload 0.3.17) is rejected by Apple (HTTP 503, then `-80045` for any
  Apple ID; not throttling). The owner's Linux box runs a **local port of that transport onto
  iloader 2.4.1** (`~/src/iloader-vp`, branch `vp-on-2.4.1`, built with Tauri; see the
  Claude memory note "vision-pro-sideload-iloader-port"). Pair once via Settings → General →
  Remote Devices (6-digit code), sign in, then **Import IPA** installs over Wi‑Fi.
  **SideStore for Vision Pro 0.7.0 also gets `-80045` at sign-in** (AnisetteKit hard-codes a
  Mac client identity). A fixed build exists: `muzam2/SideStore` release `visionos-0.7.1-signin`
  (branch `visionos-signin-fix`; identity taken from the anisette server's `/v3/client_info`,
  `adi.pb` re-provisioned automatically; CI workflow `visionos.yml`, no secrets). The iloader
  port's "Install SideStore" installs it. **Not yet tested on the headset**: if its sign-in
  works, 7-day renewals happen on-device; otherwise re-run Import IPA from the box. Apple TV:
  atvloadly (untested so far).
- Is ordering an **ESP32-A1S Audio Kit** (ES8388). Firmware target `esp32-a1s` is primary;
  `esp32dev` + PCM5102A is the alternative.
- Prefers blunt, concrete answers; happy to be told "that can't work and here's why". Asks
  "why not X?" and expects a real reason; correct yourself openly if you were wrong (that
  happened once with MVC, see §4).

## 2. What exists

Repo: `muzam2/vision-bass-player` (public). Tag/release creation was not possible from the
original session, so IPAs and firmware are **Actions artifacts** until someone pushes a `v*` tag.

```
project.yml                     XcodeGen spec: BassPlayer (visionOS 2) + BassPlayerTV (tvOS 18), same sources, KSPlayer from Vendor/
Vendor/KSPlayer                 KSPlayer GPLv3 source, vendored + patched (see §3). UPSTREAM_COMMIT = base commit
Vendor/FFmpegKit                Local FFmpegKit 6.1.4 package: shims + generated Package.swift → release zips (see §3)
Vendor/FFmpegKit-patches        Upstream FFmpeg fixes backported into Libavformat
BassPlayer/App                  App entry (main window, player window on visionOS, ImmersiveSpace), AVAudioSession, FFmpegConfig.apply(); DemoData (BASSPLAYER_DEMO=1 sample content for simulator screenshots)
BassPlayer/Media                MediaItem (server-agnostic, Codable), MediaSource, StereoFormat, ScreenProjection, LibraryStore (settings, overrides, recents, progress)
BassPlayer/Jellyfin             Password auth, movies+episodes, direct/transcode URLs, external subs, resume, progress reporting
BassPlayer/Plex                 plex.tv PIN auth, resource discovery, per-server token, direct-play, external subs, resume, timeline reporting
BassPlayer/YouTube              InnerTubeClient (search/trending/player with client fallbacks), SponsorBlockClient, YouTubeClient
BassPlayer/NAS                  NASClient (SMB via FFmpeg avio, WebDAV PROPFIND + HTML index), Keychain, NASBrowserView
BassPlayer/Player               PlayerView (resolve → backend switch, 3D/projection pickers), FFmpegPlayerView + FFmpegSession, AVPlayer fallback
BassPlayer/Audio                BassExtractor (DSP), BassEngineTap (AVAudioEngine tap + lead delay), BassTapProcessor (MTAudioProcessingTap)
BassPlayer/BLE                  BassLink: CoreBluetooth central, config/status characteristics
BassPlayer/Immersive            visionOS-only: model, flat/curved/VR meshes, ScreenTextureFeeder, ImmersiveScreenView, StereoScreen.usda
BassPlayer/Views                RootView (TabView .sidebarAdaptable: Home/Jellyfin/Plex/YouTube/NAS/Settings), HomeView, LibraryGridView (poster grid + search/filter), YouTubeView (search bar always present), SettingsView, PlayerScreen (player window / fullScreenCover), Cards (PosterCard, VideoCard, Artwork placeholder, Metrics)
firmware/esp32-bass-receiver    PlatformIO; NimBLE GATT server, 2-device arbitration, jitter buffer, drift control, I²S, ES8388 init
.github/workflows/build.yml     visionOS + tvOS unsigned IPAs (matrix), FFmpegKit zips fetched + checksum-verified, SPM cache, "FFmpeg: linked" check
.github/workflows/ui-screenshots.yml  Simulator builds (visionOS + tvOS), launches each screen with demo data, uploads PNGs (artifact screenshots-<os>)
.github/workflows/ffmpegkit-backports.yml  Rebuilds mov.o+hls.o with the patches, re-zips FFmpegKit, publishes release RELEASE_TAG once
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
6. `ImmersiveScreenBridge.shared` carries `pushFrame` (set by the cinema screen while open),
   `stereoFormat`, `projection`, `avPlayer`. `FFmpegSession` installs a `frameSink` on
   KSPlayer's `MetalPlayView` and pushes every frame (DoVi P5 colour-mapped first).
   `ImmersiveFrameFeed` turns frames into `CMSampleBuffer`s tagged with Apple Projected Media
   Profile extensions (`viewPackingKind` side-by-side / over-under, `projectionKind`) and
   enqueues them on an `AVSampleBufferVideoRenderer`; a `VideoMaterial(videoRenderer:)` on the
   flat/curved/VR mesh renders them — stereo per eye and HDR handled by the system (the approach
   OpenImmersive ships with). Software frames (VP9) are repacked to NV12/P010 by two compute
   kernels (`FrameConvert.metal`). MV-HEVC uses `VideoPlayerComponent`.
   Before 2026-11-08 this was CoreImage → `DrawableQueue` → hand-written shader graph, which
   showed a magenta (failed-material) box on the headset.

### Persisted settings
Backend, show episodes, resume, autoplay next, Jellyfin creds, Plex token/server/server-token,
NAS shares (+Keychain passwords), YouTube SponsorBlock + max quality (`yt.maxHeight`) + HDR (`yt.preferHDR`) + visitor id (`yt.visitorData`), receiver extra delay (0–400 ms, sent
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
- `MEPlayer/MetalPlayView.swift` — `frameSink` (every rendered frame, hardware or software, with
  its time) for the immersive screen; plus the Dolby Vision / `contentsCrop` changes below.
- `MEPlayer/Filter.swift` — remembers a failed `avfilter_graph_config` and passes frames through
  (upstream re-fed the half-built graph on the next frame → SIGSEGV in `config_props`; this was
  the first on-device crash, reproduced in the simulator by the E2E Plex test); rebuilds the
  graph cleanly on retry.
- `Package.swift` — tests removed; FFmpegKit comes from the local `../FFmpegKit` package.

### FFmpegKit (Vendor/FFmpegKit)
FFmpegKit 6.1.4 is stock FFmpeg n6.1. Four upstream libavformat fixes are backported
(`Vendor/FFmpegKit-patches`): duplicate mastering-display boxes (YouTube HDR), duplicate
`ftyp`, fragment/index reset when HLS seeks back to pos 0 (trac #7359), HLS init-section read
pointer. Seeking in VP9 fMP4 HLS needs both the `ftyp` and reset fixes. Verified on desktop
FFmpeg n6.1 (stock vs patched, same streams: VP9 seek at 0.5/30/250/310 s, 4K HDR open,
H.264 HLS unchanged).
`.github/workflows/ffmpegkit-backports.yml` rebuilds FFmpeg with FFmpegKit's own plugin (same
configure line), splices only `mov.o` + `hls.o` into the released Libavformat (visionOS arm64,
tvOS arm64; tvOS arm64e kept original since apps don't link it), strips every xcframework to
the visionOS/tvOS slices (device patched, simulator stock), zips them and publishes release
`ffmpegkit-6.1.4-bp2` once (an existing tag is never overwritten; bp1 was device-only).
`Package.swift` is generated by `tools/package_xcframeworks.py` with path-based binary targets;
`tools/fetch_binaries.sh` downloads the zips with `gh` and verifies `checksums.json` (SwiftPM's
own binary download failed in CI). Commit Package.swift + checksums.json + RELEASE_TAG from the
workflow artifact.

Dolby Vision P5 needs `KSOptions.asynchronousDecompression = false` (FFmpeg hwaccel path) so
the RPU side data reaches the frame. P7/P8 bypass the mapping (HDR10/HLG base layer).

## 4. Known risks — check these first on hardware

Ordered by likelihood of needing a fix.

1. **Dolby Vision P5 colours wrong** — sign of offsets, limited-vs-full range, matrix
   orientation in `doviToPQ`. Compare with the Apple TV app on the same film. Reference:
   libplacebo `src/shaders/colorspace.c` (`pl_shader_dovi_reshape`, DOLBYVISION branch).
2. **Cinema screen (rewritten 2026-11-08, untested on hardware).** Design target (owner's
   words + screenshots of Plexi/Skybox/Moon): a black void, a very large screen (~85° of view by
   default), subtitles along the picture's bottom edge, a floating glass control panel under the
   screen that appears on tap and fades while playing, and **no app window**. Playback therefore
   lives in `LibraryStore.playback` (`PlaybackController`: KSPlayer coordinator + FFmpegSession);
   the cinema dismisses the player window on appear (`detachedForImmersive`, and KSPlayer's
   `Coordinator.keepsPlayerWhenViewGoesAway` patch keeps the player alive without its view) and
   reopens it on exit. Stop ends playback and closes everything. First on-device attempt
   showed the black dome with a magenta box (RealityKit's failed-material colour) and the
   settings popover did nothing. Now: native `AVSampleBufferVideoRenderer` + `VideoMaterial`
   path (§2 data flow 6), the player window becomes a remote (controls + screen settings
   inline, picture hidden) while the screen is open, Stop button closes everything. Check the
   log (Settings → Diagnostics → Send log) for `immersive |` lines: "video material created",
   "first frame enqueued", "format …", "status: pushed N". If frames are pushed but the screen
   stays black, suspect `VideoMaterial(videoRenderer:)` on a custom mesh → try
   `VideoPlayerComponent(videoRenderer:)` on the entity instead (flat screen only). Picture
   controls (brightness/contrast/saturation) were dropped with the CoreImage path.
2b. **Subtitles / audio tracks (2026-11-08).** KSPlayer's stock view hid its subtitle menu in a
   scene ornament that collided with the app's; visionOS now uses the app's own chrome
   (`Player/PlayerChrome.swift`: transport, scrubber, audio/subtitle/speed menus, 3D +
   projection pickers, cinema toggle, Stop; controls and the bass-tap chip fade after 4 s).
   Subtitles render via `SubtitleOverlay` from KSPlayer's `SubtitleModel.parts`. tvOS still
   uses `KSVideoPlayerView`.
3. ~~Player crashes on play~~ — FIXED 2026-11-08: `autoDeInterlace` put the software `idet`
   filter into the VideoToolbox pipeline; the graph failed to configure and KSPlayer then
   pushed frames into it. Now off in `FFmpegConfig.makeOptions`, and `Filter.swift` tolerates
   configuration failures. Repro: E2E test `testPlexLibraryAndPlay` (crash log in the artifact).
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
   in `InnerTubeClient.swift` from yt-dlp `youtube/_base.py` (INNERTUBE_CLIENTS) and
   `_video.py` (`_DEFAULT_JSLESS_CLIENTS`). State checked 2026-11-08 from the owner's home IP:
   VISIONOS + visitor id → HLS to 2160p60 incl. HDR, every segment fetchable without a PO
   token; IOS has HLS only for some videos (otherwise adaptive URLs 403 after ~1 MB);
   ANDROID_VR bot-checked, TV embedded retired, WEB unplayable. Without a visitor id
   VISIONOS gets "Sign in to confirm you're not a bot". "Made for kids" videos don't play on
   VISIONOS (falls back to IOS).
   HDR variants (VP9 profile 2, PQ) are picked when "HDR when available" is on: first thing to
   check on hardware is whether 4K60 10-bit VP9 decodes in real time (VideoToolbox VP9 on M2 /
   A15 is unconfirmed; FFmpeg falls back to software). Seek/resume rely on the FFmpegKit
   backports (§3). Verified on desktop FFmpeg n6.1 with the same streams; not yet on hardware.
8. **SMB against SMB3-only NAS** — libsmbclient should negotiate; options go through
   `NetworkDirectory.list(options:)`. Guest access with empty username on Windows untested.
8b. **Jellyfin library size** — same treatment as Plex (series cards + `Shows/{id}/Episodes`,
   movies paged 500 at a time, decode off the main thread). Untested against a real server
   since the change.
8c. **YouTube account (2026-11-08, untested).** Google sign-in in a `WKWebView`
   (`YouTube/YouTubeAccount.swift`); youtube.com cookies stay in WebKit's store; feeds use the
   WEB client with `SAPISIDHASH` + cookies (`InnerTubeClient.browse`), parsed by a generic
   walker that knows the old renderers and the 2024+ `lockupViewModel`. Feeds: Home
   (`FEwhat_to_watch`), Subscriptions, History, Watch later (`VLWL`), Liked (`VLLL`), Playlists
   (`FElibrary`) → `VL<id>`. Playback stays anonymous (visitor id). Risks: Google refusing the
   embedded browser ("this browser may not be secure") — then try a desktop Safari user agent on
   the WKWebView; `FElibrary` layout changing — check `DiagLog` "browse … → N videos".
9. **Plex library size.** Series are listed as one card each and open a season/episode page
   (`ShowEpisodesView`, episodes from `/library/metadata/<id>/allLeaves`, cached for
   autoplay-next); movies load in pages of 500 (`X-Plex-Container-Start/Size`, title-sorted,
   cast/genre elements excluded) and appear as each page lands; JSON is decoded off the main
   thread. Before 2026-11-08 the app fetched every episode of every show in one go — 134 MB of
   JSON on the owner's server — and the spinner never ended (seen on the headset and in CI).
10. **Plex connection choice**: `connect(to:)` probes every advertised address (plus an
   `http://IP:port` twin for each LAN `plex.direct` one) with `/identity` and takes the first
   that answers, LAN first, relay last; a stale saved address triggers one rediscovery. The
   owner's OpenWrt router has `plex.direct` in dnsmasq's `rebind_domain`; other users with
   rebind protection fall back to the http twin automatically.
11. **Firmware drift control** nudges one sample per second when off by >15; scale with error
    if the buffer still drifts. **A1S line-out level** may clip some subs: lower registers
    0x2E–0x31 in `codecInit()` (0x1E ≈ 0 dB, ~1.5 dB per step). **AC101 variant** unsupported.
12. ~~Free-ID signing prompts~~ — Local Network permission was present after the first
    install (2026-11-08). Bluetooth prompt still to be seen once the receiver exists.
13. **New UI untested on hardware** (built 2026-11-08, checked only in the simulator via
    `ui-screenshots.yml`): TabView `.sidebarAdaptable`, player in a separate window on
    visionOS (`WindowGroup(id: "player", for: MediaItem.self)`), `fullScreenCover` on tvOS.
    tvOS focus behaviour in the grids and the YouTube text field needs a look on the Apple TV.

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
- **Seeing the UI without a headset:** `gh workflow run ui-screenshots.yml --ref <branch>`
  (also runs on pushes to `ui-redesign`). It builds for the visionOS and tvOS simulators,
  launches with `BASSPLAYER_DEMO=1` + `BASSPLAYER_SCREEN=<tab>` and uploads one PNG per screen.
  `DemoData.swift` seeds the clients (`enableDemo` on Jellyfin/Plex/YouTube) and a few
  part-watched items. Download with `gh run download <id> -n screenshots-visionos`.
- **Logs from the headset:** Settings → Diagnostics → "Send log to computer" posts the in-app
  log (`DiagLog`, app + KSPlayer messages) to `tools/diag_receiver.py` running on the LAN box
  (`python3 tools/diag_receiver.py --bind <ip> --port 8799 --dir <ipa dir>`; logs land in
  `<dir>/logs/`). The same server serves the `.ipa` for installing through SideStore in Safari.
- **Installing on the Vision Pro from the Linux box:** launch the ported iloader
  (`~/src/iloader-vp/src-tauri/target/release/iloader`, DISPLAY=:10), headset awake, Import IPA
  with the artifact's `.ipa`. The same step renews the 7-day signature.

## 7. Suggested next steps, in order

1. **First-run support, continued.** The app is on the headset; Plex/NAS/YouTube fixes and the
   new UI need a second on-device pass. Then the A1S arrives: flash, pair, work down §4.
2. **Timing tune.** One-tap "measure latency": send a tagged click, read the receiver's
   played-timestamp back over the status characteristic, auto-set `bass.leadMs`.
3. **Immersive polish.** Hide/shrink the 2D window while the cinema screen is open; a small
   play/pause/seek attachment on the screen; left/right swap toggle.
4. **MVC via edge264-mvc** (§5) once a test file is on the owner's server.
5. **Library UX, next round.** Group episodes by series (season pages), a detail sheet with
   overview/cast before playing, poster caching for large libraries.
6. **Firmware extras.** Optional Wi‑Fi (UDP) transport for higher-rate bass and lower latency;
   OTA updates.
7. **Release hygiene.** Owner pushes `v0.3.0`; both workflows attach artifacts to the release.
