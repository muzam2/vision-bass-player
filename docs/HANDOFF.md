# Handoff — Bass Player

## 0. Start here (the daily loop, as of 2026-11-08 night)

- **Repo:** `~/src/vision-bass-player` on the Linux box (`/home/remoteuser`), remote
  `https://github.com/muzam2/vision-bass-player`, branch `main`. Nothing builds locally; **CI
  is the compiler** (`.github/workflows/build.yml`, runner `macos-15` + latest Xcode, ~25–35 min).
- **Build:** push to `main` (or `gh workflow run build.yml --ref <branch>`), then
  `gh run watch <id> --exit-status`; errors with `gh run view <id> --log-failed | grep error:`.
  Artifact: `gh run download <id> -n BassPlayer-visionos-unsigned-ipa -D <dir>`.
- **Serve + install:** copy the `.ipa` to `~/Downloads/ipa-serve/BassPlayer.ipa`. The LAN
  helper `python3 -I tools/diag_receiver.py --bind 192.168.0.191 --port 8799 --dir ~/Downloads/ipa-serve`
  serves it; on the headset: Safari → `http://192.168.0.191:8799/BassPlayer.ipa` → Download →
  SideStore (Vision Pro build 0.7.2 from `muzam2/SideStore`, release `visionos-0.7.2-signin`)
  → My Apps → "+" → pick the file. Same bundle id, data preserved. SideStore refreshes the
  7-day signature itself. (The ported iloader at `~/src/iloader-vp` still works as a fallback.)
- **Logs:** the headset streams its log live (Settings → Diagnostics → "Stream log live to
  computer", remembered across launches) into `~/Downloads/ipa-serve/logs/live-Apple_Vision_Pro.log`;
  `tail -f` it while the owner tests. App lines are `category | message`; KSPlayer's are `ks:`.
- **Owner's constraints:** no Mac, free Apple ID, Plex token never printed, no PHI in chat,
  don't fork public repos on his behalf without asking (§1).

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
Vendor/FFmpegKit-patches        Upstream FFmpeg fixes backported into Libavformat (6.1.4 era; retired by FFmpegKit 9)
Vendor/AMSMB2                   libsmb2 + Swift wrapper (4.0.3, LGPL-2.1), vendored only to make the product static
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
BassPlayer/Views                RootView (TabView .sidebarAdaptable: Home/Jellyfin/Plex/YouTube/NAS/Settings), HomeView, LibraryGridView (Home rows of `Shelf`s + "See all" `ShelfGridView`, Library poster grid + search/filter), YouTubeView (search bar always present), SettingsView, PlayerScreen (player window / fullScreenCover), Cards (PosterCard, VideoCard, Artwork placeholder, Metrics)
firmware/esp32-bass-receiver    PlatformIO; NimBLE GATT server, 2-device arbitration, jitter buffer, drift control, I²S, ES8388 init
.github/workflows/build.yml     visionOS + tvOS unsigned IPAs (matrix), FFmpegKit zips fetched + checksum-verified, SPM cache, "FFmpeg: linked" check
.github/workflows/ui-screenshots.yml  Simulator builds (visionOS + tvOS), launches each screen with demo data, uploads PNGs (artifact screenshots-<os>)
.github/workflows/ffmpegkit-backports.yml  Rebuilds mov.o+hls.o with the patches, re-zips FFmpegKit, publishes release RELEASE_TAG once
.github/workflows/firmware.yml  Both ESP32 envs, uploads .bin + bootloader + partitions
docs/SETUP-GUIDE.md             End-user step-by-step (hardware, flashing, sideloading, sources, tuning)
```

### Server Home rows (2026-11-13, `Media/Shelf.swift`)
The Plex and Jellyfin tabs open on native-app-style rows. Each client has `shelves`,
`loadShelves()` (all rows in parallel; a failing row is logged as `plex|jellyfin` and
omitted) and `shelfItems(kind, limit:)` (24 for the row, 300 for See all).
- Plex: Continue Watching = `/hubs/continueWatching?count=` → fallback `/library/onDeck`
  (first one with playable items); the rest are `/library/sections/<k>/all` with `sort=`
  `addedAt:desc`, `episode.addedAt:desc` (shows; falls back to `addedAt:desc`),
  `originallyAvailableAt:desc` (type 1 / type 4) and `lastViewedAt:desc` (unviewed dropped),
  merged across sections by that date. Plex has no separate Up Next (it is in On Deck).
- Jellyfin: `Users/<id>/Items` with `Filters=IsResumable` / `IsPlayed`, `SortBy=DatePlayed`,
  `DateCreated`, `DateLastContentAdded` (series), `PremiereDate` + `MaxPremiereDate=now`;
  Up Next = `Shows/NextUp` minus anything already in Continue Watching.
- Rows refresh after a `.stopped` report (`LibraryStore.report`) and when the tab reappears
  after 60 s. Cards use `displayProgress` (local position, else the server's resume point).
- `MediaItem.artURL` (episode still / backdrop) and `showTitle` were added; episode
  `posterURL` is now the **series** poster (Plex `grandparentThumb`, Jellyfin
  `Items/<SeriesId>/Images/Primary`); `EpisodeCard` uses `artURL`.
- **Unverified against a real server** at the time of writing: the Plex hub endpoint and
  `episode.addedAt` sort are the likeliest to differ by PMS version; each has a fallback.

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
**Branch `ffmpegkit-9` (2026-11-08): stock FFmpegKit 9.0.2 = FFmpeg 9.0.2.** Release
`ffmpegkit-9.0.2-vt1` of this repo holds the tag's 22 xcframeworks stripped to visionOS +
tvOS slices plus `FFmpegKit-sources.zip` (the C shim target), produced by
`.github/workflows/ffmpegkit-repack.yml` + `tools/repack_release.py` (sparse clone of the tag:
its binaries are committed in git, there are no upstream release assets). `Package.swift`,
`checksums.json`, `RELEASE_TAG` are the workflow's artifact; `tools/fetch_binaries.sh` unpacks
everything, so `Sources/FFmpegKit` is no longer in git either. The 6.1.4 backports below are
upstream in 9.0.2 and `ffmpegkit-backports.yml` is retired once the branch merges. KSPlayer
port: `avcodec_close` removed, closed captions detected from `AV_FRAME_DATA_A53_CC` side data
(`AVCodecContext.properties` is gone), `NetworkDirectory.swift` deleted (SMB bridge).

The paragraphs below describe the 6.1.4 setup still on `main` until the branch merges.
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

### SMB bridge (BassPlayer/NAS/SMBBridge.swift, 2026-11-08)
SMB no longer goes through FFmpeg. `AMSMB2` (libsmb2, LGPL-2.1, SwiftPM) lists shares and
directories and reads files; a loopback HTTP/1.1 server (Network.framework, 127.0.0.1, random
port) exposes each file as `http://127.0.0.1:<port>/smb/<share id>/<path>` with byte-range
support, so FFmpeg *and* AVPlayer can open NAS files (MV-HEVC from a NAS can go to AVPlayer).
One libsmb2 context per in-flight request (small per-share pool), one chunk in flight for
back-pressure, `Connection: close` per request (FFmpeg reconnects on seek, AVPlayer makes
parallel ranged requests). This removes the only reason to keep libsmbclient in FFmpeg, which
is the prerequisite for FFmpegKit 9 (below). KSPlayer's `NetworkDirectory` patch is now unused.
**Gotcha found the hard way:** the remote AMSMB2 package is a *dynamic* SwiftPM product and
the xcodegen-generated project did not embed it (no `Frameworks/AMSMB2.framework` in the IPA
while the binary loads `@rpath/AMSMB2.framework/AMSMB2`), i.e. a dyld crash at launch. It is
vendored under `Vendor/AMSMB2` with `type: .dynamic` removed in both manifests, and build.yml
now fails when any `@rpath/*.framework` the binary references is missing from `Frameworks/`.
FFmpegKit's own xcframeworks are dynamic too (they are embedded fine, hence the ~20 MB IPA).

### FFmpegKit 9.0.2 (plan, started 2026-11-08)
Facts checked: kingslay/FFmpegKit's latest tag is 9.0.2 = FFmpeg 9.0.2 (lavu 61.1, lavf 63);
all four of our n6.1 backports are upstream in it (mov.c duplicate mastering/ftyp, seek reset
at pos 0, hls init-section offset). The xcframeworks are committed in the repo at the tag
(no release assets; xros slices 216 MB, tvos 297 MB). libsmbclient and gnutls are gone;
libssl/libcrypto, libopus, libdovi, libplacebo and a `renderer.c` are new in `Sources/FFmpegKit`.
Upstream KSPlayer moved to 9.0.2 on 2026-10-07 but its FFmpeg-facing code is now a binary
`KSPlayer.xcframework`, so the API port of our vendored (2026-10-05, source) copy is ours to
do: known removals are two `avcodec_close` calls; the rest will surface as compile errors.
Steps: (1) SMB bridge — done; (2) workflow `ffmpegkit-repack.yml`: sparse-clone the tag,
strip to visionOS/tvOS, zip, checksums, generated Package.swift + the tag's `Sources/FFmpegKit`
shims, publish release `ffmpegkit-9.0.2-vt1`; (3) point `Vendor/FFmpegKit` at it, port
KSPlayer, drop `NetworkDirectory.swift`; (4) later: MV-HEVC through FFmpeg instead of AVPlayer.

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
   reopens it on exit. Stop ends playback and closes everything (from the cinema: closes the
   space first, the reopened window finishes the stop — `stopAfterCinema`). Second device pass
   (same day): log uploads arrived empty (file-handle logger rewritten to an in-memory ring),
   the screen showed as a grey sliver (no frames reaching the renderer? aspect now clamped and
   logged; a live debug line sits on the panel), the panel was under the far-away screen (now
   anchored 1.35 m in front of the viewer), tapping the panel hid it (tap toggles only on the
   screen/backdrop now), default curve is 0 with a Curve slider on the panel. First on-device attempt
   showed the black dome with a magenta box (RealityKit's failed-material colour) and the
   settings popover did nothing. Now: native `AVSampleBufferVideoRenderer` + `VideoMaterial`
   path (§2 data flow 6), the player window becomes a remote (controls + screen settings
   inline, picture hidden) while the screen is open, Stop button closes everything. Third
   device pass (2026-11-08 evening): **the native cinema path works** — the user's screenshots
   show the film on the big screen with subtitles and the audio menu; the earlier grey band was
   a one-off. Remaining complaints that pass: subtitles too large (now a shared "Subtitle size"
   setting, `SubtitleSize.key`, Aa menu in the transport bar + picker in the screen sheet;
   cues are drawn as plain strings because the parsed cue's own font attributes overrode the
   SwiftUI font), audio labels too long for visionOS menu rows (`TrackLabel.cleanTitle` strips
   the language and abbreviates codecs), closing the player window with its close button left
   audio running (SwiftUI `onDisappear` is not delivered for a window closed that way — the
   controller now watches `UIScene.didDisconnectNotification` for the player window's scene,
   found via `WindowSceneProbe`, and pauses on `didEnterBackground`), the cinema's Stop/Exit
   now open the library/player window *before* dismissing the space instead of relying on the
   space's onDisappear (`stopAfterCinema` is gone). Log uploads arrived as 1 byte because the
   Diagnostics row held three plain Buttons in one HStack inside a Form: in a List row they all
   fire on one tap, so "Send" also ran "Clear" first. Each control is now its own row, and a
   "Stream log live to computer" toggle posts new lines every 2 s (`DiagLog.setLive`,
   receiver appends to `logs/live-<device>.log`). Picture controls
   (brightness/contrast/saturation) were dropped with the CoreImage path. Fourth pass (same
   evening, first one with the live log stream): (a) a visionOS window closed with its close
   button keeps its SwiftUI view tree alive and *updating* — KSPlayer's `updateUIView` then
   re-created the player 80 ms after `end()` (so Stop/close "didn't work"), and the ghost's
   autoplay opened a second item when a film ended. `KSVideoPlayer.updateView` no longer
   resurrects a nil player layer under `keepsPlayerWhenViewGoesAway`, and `PlayerScreen` goes
   inert once its `UIWindowScene` disconnects. (b) The space's onDisappear was not delivered
   on one exit, leaving `isOpen`/`detachedForImmersive` stuck ("Playing on the cinema screen"
   over a window). Closure bookkeeping is now `ImmersiveScreenModel.noteClosed` (idempotent),
   run after every `dismissImmersiveSpace()` we issue, from onDisappear, and from
   `reconcile()` when a window appears/activates and the space's frame tick is stale. (c) The
   library window is dismissed while the cinema is up and reopened on exit. (d) In the cinema
   `PlaybackController` creates the player itself (`coordinator.makeView`) and runs autoplay
   (`autoplayNextInCinema`) since no window exists. (e) YouTube dubbed videos: the HLS master
   picker preferred DEFAULT=YES, which YouTube sets on a dub (Japanese); now original →
   device language → DEFAULT → first, and every rendition is kept (preferred first) so the
   audio menu can switch; KSPlayer discards unselected streams so only one is downloaded.
   Fifth pass: the screen ignored where the user was looking (recentre fired 300 ms after
   tracking started, before a device anchor existed, and only used yaw). Placement is now the
   gaze line: `recentre` sets yaw *and* tilt (pitch) from the head pose, `height` is an offset
   from that line, `ImmersiveScreenModel.position` puts the screen `distance` along it, the
   HUD follows the same line, dragging moves the screen on a sphere around the viewer; the
   initial recentre retries until the anchor is tracked. Height/Tilt sliders are on the cinema
   panel (second row). `openWindow(id:)` on the value-less library WindowGroup opens a new
   instance each call — three callers left three library windows — so `MainWindowTracker`
   opens one only when no library scene is connected.
   Sixth pass — **judder on every film**: the live log showed `[video] video delay=-0.2 …
   drop next frame` every 80–400 ms with 9–16 decoded frames queued, in the window and in
   the cinema alike. Cause: `KSOptions.preferredFrame` paces `MetalPlayView`'s CADisplayLink
   at the content rate (24 ± range 24–48); the 90 Hz panel cannot do that and settles on a
   divisor (22.5/18 Hz), so rendering runs slower than the film and the clock sync drops
   frames in bursts. Now `preferredFrame = false` (made public) and on visionOS the link asks
   for 60–120 Hz, preferred 4× the film rate (96 for 24p, if the panel grants it). Residual
   3:4 cadence judder at 90 Hz is inherent unless the system grants 96 Hz. Also seen: ~30
   `spatialPlaybackCapabilitiesChanged` notifications in 200 ms when the immersive space
   opens; KSMEPlayer reconfigures audio on each (one-off hiccup at cinema open, not fixed).
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

- **Blu-ray 3D (frame-packed MVC) — DONE 2026-11-08, untested on device.** `Vendor/edge264-mvc`
  (BSD-3, commit 515a7ba, one C translation unit, its own local SwiftPM package with the
  Makefile's iOS flags) + `Vendor/KSPlayer/.../MEPlayer/Edge264Decode.swift`, a
  `DecodeProtocol` picked in `makeDecode(assetTrack:firstPacket:)` when the H.264 track is
  profile 118/128 or the first packet carries NAL 14/15/20 (`KSOptions.mvcSoftwareDecode`).
  NALs are fed one by one (avcC length-prefixed or Annex B; SPS/PPS from avcC first and after
  every flush); each decoded pair is packed into ONE full side-by-side NV12 CVPixelBuffer
  (base | dependent) so the existing packed-3D path does the rest: the track sets
  `decodesStereoSideBySide`, `FFmpegSession.poll` sees it and re-applies stereo as `.sbsFull`
  (window crops to the left eye, cinema gets `viewPackingKind = sideBySide`), the chip says
  "3D MVC". Falls back to FFmpeg (2D base view) if the decoder fails, like VideoToolbox.
  Not handled: m2ts/ssif with the dependent view on a separate PID (needs stream merging),
  10-bit MVC (does not exist on Blu-ray). Perf unknown on M2: 1080p ×2 software decode at 24p
  should fit (edge264 is faster than FFmpeg's h264 per the project's benchmarks), watch the
  `video delay` lines in the log. Offline alternative remains BD3D2MK3D/FRIM → half-SBS MKV.
- **App icon (2026-11-08):** `tools/make_icons.py` (Pillow) generates the visionOS layered
  icon (`BassPlayer/Assets.xcassets/AppIcon.solidimagestack`) and the tvOS layered icon + top
  shelf images (`Assets-tvOS.xcassets`); each target excludes the other's catalog in
  project.yml. Re-run the script to change the artwork; `docs/icon-preview.png` is the flat look.
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
  `<dir>/logs/`). "Stream log live to computer" (remembered across launches) appends new lines
  every 2 s to `<dir>/logs/live-<device>.log` — `tail -f` it while the user tests. "Show log"
  is a live tail inside Settings. The same server serves the `.ipa` for installing through
  SideStore in Safari.
- **Installing on the Vision Pro:** see §0 (Safari download from the diag receiver → SideStore
  "+"). Fallback: the ported iloader (`~/src/iloader-vp/src-tauri/target/release/iloader`,
  DISPLAY=:10), headset awake, Import IPA.

## 7. Suggested next steps, in order

0. **Verified on device 2026-11-10 (21 Bridges, 4K HEVC, DTS-HD MA 5.1):** the bass tap
   works — mixer tap delivers 48 kHz 6-channel planar buffers, the extractor takes the LFE
   channel (index 3), ~50 packets/s, levels follow the film; BLE stays "scanning" (no
   receiver yet). visionOS keeps 5.1 → spatial audio renders it, so LFE is not lost in a
   downmix. Found + fixed: the tap was installed before the graph ran, so the extractor was
   configured from the placeholder 44.1 kHz stereo format and decimated 9 % too fast (now
   waits for the running engine and re-reads every buffer's format). Judder fix confirmed:
   8 frame drops in a minute, all at cinema open / unpause / window reopen, none in steady
   state (was ~700/min). Cinema gaze-line placement, exit and library reopen all behaved.
0b. **YouTube seek/perf, measured 2026-11-10** ("Diablo 2 … 8K", 2160p60 VP9 → VideoToolbox
   refuses VP9 on the headset, software decode): three seeks resumed after 8.6 / 2.8 / 5.0 s —
   the seek itself takes <1 ms (inaccurate seek lands on the segment keyframe), the wait is
   fetching the segment plus KSPlayer's `preferredForwardBufferDuration` (was 4 s of 4K60
   software decode) → now 1.5 s. Steady state dropped ~2 frames/s at a constant −75 ms lag
   (decoder queue full, so the renderer/upload of 4K60 software frames is the limit) → the
   variant picker now keeps software-decoded variants within a pixel-rate budget
   (`HLSVariantPicker.softwareDecodePixelRateBudget`, 1440p60 / 2160p30 pass, 2160p60 does
   not); H.264 variants are unaffected. "keepalive request failed" after seeks is FFmpeg's
   HLS persistent-connection retry against googlevideo — now disabled (`http_persistent=0`).
   Second round (same day, 1440p60 VP9): seeks resumed in 1.0–3.1 s with zero drops and A/V
   together (`isSecondOpen` off). Remaining latency is FFmpeg's HLS seek reading the segment
   that contains the target and discarding up to the first keyframe ≥ target = the *next*
   segment start, so ~1.5 segments were fetched per seek. Now `FFmpegSession.learnSegments`
   reads the media playlist once and `KSOptions.seekSnap` (patch, applied in
   `KSMEPlayer.seek`) snaps every user seek down to a segment start (sponsor skips bypass it);
   buffer requirement 1.0 s. Expect ~1–1.5 s.
   Seen once: a TCP reset from googlevideo mid-segment → FFmpeg's `reconnect_streamed` restarted
   the segment at byte 0 → duplicated bytes → VP9 header errors → video frozen 12 s, audio on
   (self-recovered at the next keyframe). YouTube sessions now set `reconnect=1,
   reconnect_streamed=0, reconnect_on_network_error=1, reconnect_delay_max=2`.
   **Look to Scroll** (visionOS 26): `View.lookToScroll()` on RootView and PlayerScreen; the
   user must also enable it in the headset's Settings.
1. **On-device verification of the remaining changes** (built, not yet confirmed on the headset): FFmpegKit 9.0.2 (Plex/Jellyfin film with subtitles, YouTube seek, Dolby Vision P5),
   the SMB bridge (NAS browse + play), MVC 3D Blu-ray (needs a MakeMKV 3D MKV on the server;
   watch `video delay` lines for decode speed), the new icon, the judder fix (display link at
   panel rate — "drop next frame" lines should be rare).
2. **MVC follow-ups if it works:** left/right swap toggle, SSIF/m2ts with the dependent view on
   its own PID (stream merge), a "3D MVC" badge on library cards (needs server metadata).
3. **Timing tune** once the ESP32 arrives: one-tap "measure latency", auto-set `bass.leadMs`.
4. **Cinema polish:** environments other than black (owner wants black for now), picture
   controls (brightness/contrast were dropped with the CoreImage path; libplacebo is now in the
   FFmpeg build and could do tone mapping), debounce the 30 `spatialCapabilityChange`
   notifications at cinema open.
5. **Library UX:** detail sheet before playing, poster caching for large libraries.
6. **Firmware extras:** Wi‑Fi (UDP) transport, OTA.
