# Bass Player for Apple Vision Pro and Apple TV

A visionOS / tvOS video player that streams the low-frequency channel of whatever you're watching
to a powered subwoofer over Bluetooth LE, while the full mix plays through the headset's
audio pods or AirPods.

```
Jellyfin server ──HTTP──▶ Vision Pro app ──BLE (1 kHz sub-bass)──▶ ESP32 + PCM5102A ──RCA──▶ powered sub
                                 │
                                 └─▶ built-in audio pods / AirPods (full mix)
```

Built without a Mac: GitHub Actions produces **unsigned IPAs** for both platforms. Sideload with a
free Apple ID: iloader / SideStore for the Vision Pro (wireless pairing, no dev strap),
[atvloadly](https://github.com/bitxeno/atvloadly) for the Apple TV. Both talk to the same ESP32
receiver, so one sub serves the headset and the TV.

This is one person's home project, shared as it is. It is in use on the author's Vision Pro
(visionOS 27) with the ESP32-A1S receiver. The Apple TV app is compiled by CI but has not been
run on an Apple TV yet.

## Get it

| What | Where |
|---|---|
| App (`…-visionos-unsigned.ipa`, `…-tvos-unsigned.ipa`) and receiver firmware (`.bin` files) | [Latest release](https://github.com/muzam2/vision-bass-player/releases/latest) |
| Bass sync calibration videos | Same release (`bass-sync-sweep.mp4`, `bass-sync-steady.mp4`) |
| iloader with Vision Pro support (Linux build, or source) | [muzam2/iloader releases](https://github.com/muzam2/iloader/releases) |
| SideStore for Vision Pro (optional, renews the app on the headset) | [muzam2/SideStore `visionos-0.7.3-autorenew`](https://github.com/muzam2/SideStore/releases/tag/visionos-0.7.3-autorenew) |

You need: an Apple Vision Pro on visionOS 26 or later and/or an Apple TV on tvOS 18 or later, a
free Apple ID, a powered subwoofer with a line input, and an ESP32-A1S Audio Kit (about £15).
The player works without the receiver; you just get no sub. **docs/SETUP-GUIDE.md** walks
through everything in order.

## Repo layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec with two targets, `BassPlayer` (visionOS) and `BassPlayerTV` (tvOS), sharing all sources |
| `Vendor/KSPlayer` | KSPlayer GPLv3 source, vendored and patched (Dolby Vision P5, frame renderer, FFmpeg 9 API, seek and pacing fixes). `UPSTREAM_COMMIT` records the base. |
| `Vendor/FFmpegKit` | FFmpeg 9.1 package: build recipe and patches; the binaries are release assets fetched by `tools/fetch_binaries.sh` |
| `Vendor/AMSMB2`, `Vendor/edge264-mvc` | SMB client (libsmb2) and the MVC (3D Blu-ray) decoder |
| `BassPlayer/App` | SwiftUI app entry, audio session |
| `BassPlayer/Media` | `MediaItem` model shared by both servers, `LibraryStore` (source/backend settings) |
| `BassPlayer/Jellyfin`, `BassPlayer/Plex`, `BassPlayer/YouTube`, `BassPlayer/NAS` | Sources: media servers, YouTube (InnerTube + SponsorBlock), NAS shares (SMB / WebDAV) |
| `BassPlayer/Player` | `FFmpegPlayerView` (KSPlayer) and the AVPlayer fallback |
| `BassPlayer/Audio` | `BassExtractor` (LPF → 1 kHz Int16 packets), `BassEngineTap` (AVAudioEngine tap + lead delay), `BassTapProcessor` (MTAudioProcessingTap glue for AVPlayer) |
| `BassPlayer/Immersive` | RealityKit cinema screen (visionOS only) |
| `docs/SETUP-GUIDE.md` | Step-by-step hardware, install and tuning guide |
| `docs/HANDOFF.md`, `CLAUDE.md` | Handoff for the next Claude Code session: state, risks, next steps |
| `BassPlayer/BLE` | `BassLink` CoreBluetooth central |
| `BassPlayer/Views` | Library, settings, status ornament |
| `firmware/esp32-bass-receiver` | PlatformIO project for the ESP32 receiver |
| `tools/receiver_test.py` | Test the receiver from a computer: serial boot log, BLE scan, test tone / thumps through the sub |
| `tools/make_bass_sync_videos.py` | Generates the bass sync calibration videos (click + 50 Hz thump) |
| `tools/diag_receiver.py` | Small LAN server: receives the app's diagnostics log and serves IPAs to the headset |
| `docs/RECEIVER-BRINGUP.md` | First power-on of the receiver: the boot-loop crash, its fix, and what was tested |
| `.github/workflows/build.yml` | Builds the unsigned IPAs on a macOS runner |
| `.github/workflows/firmware.yml` | Builds the receiver firmware for both boards |

## Status

See **docs/SETUP-GUIDE.md** for the step-by-step setup.

- **Playback:** [KSPlayer](https://github.com/kingslay/KSPlayer) (GPLv3 branch, FFmpeg 9.1) is
  the default backend. Direct-plays MKV/MP4/MOV/TS/AVI with H.264, HEVC, AV1, VP9, ProRes and
  more; audio AAC, AC‑3, E‑AC‑3, DTS, DTS‑HD, TrueHD, FLAC, Opus; HDR10 and HLG passed to the
  display. Hardware decoding via VideoToolbox. AVPlayer remains as a fallback backend (MP4
  only; Jellyfin remuxes for it).
- **Dolby Vision:** profile 8 (HDR10/HLG-compatible base layer) and profile 7 (plays its HDR10
  base layer; the enhancement layer is dropped) work through the normal HDR path. **Profile 5**
  (IPT‑PQ‑C2, the streaming-service flavour) is handled by a patch in the vendored KSPlayer:
  FFmpeg's RPU parser supplies the per-frame reshaping curves and colour matrices, and a Metal
  shader (`displayDovi*Texture`) applies polynomial/MMR reshaping, the IPT→LMS→RGB matrices and
  PQ encoding, mirroring libplacebo's approach. The same renderer feeds the immersive screen.
  Dynamic tone-mapping metadata (DM level 1–11) is not applied; the display gets PQ BT.2020.
- **Servers:** Jellyfin (username/password) and Plex (plex.tv PIN sign-in, server discovery,
  per-server tokens). Both map into one `MediaItem` model; movies and TV episodes.
- **Bass:** with the FFmpeg backend the tap sits on KSPlayer's `AVAudioEngine` mixer, picking
  the LFE channel for 5.1/7.1 tracks. A "Bass lead" setting inserts an `AVAudioUnitDelay`
  before the output and delays video by the same amount, so the sub's BLE latency is cancelled.
- **Immersive screen (visionOS):** RealityKit cinema screen: decoded frames go to an
  `AVSampleBufferVideoRenderer` and a `VideoMaterial` on a flat, curved or sphere mesh. Drag /
  pinch / rotate gestures plus sliders, full immersion by default.
- **3D:** side-by-side and top-and-bottom (half and full), detected from Jellyfin's
  `Video3DFormat`, file-name tokens (HSBS, SBS, HOU, 3D…) and frame shape, with a per-film
  override in the player. On the Vision Pro cinema screen the frames are tagged with their
  packing, so the system shows each eye its half. On the flat window and on Apple TV one eye is
  shown, un-squeezed. MV-HEVC / Apple spatial video plays through AVPlayer and RealityKit's
  `VideoPlayerComponent`, which renders stereo natively. Blu-ray MVC is decoded by the bundled
  edge264 decoder into a side-by-side frame.
- **YouTube:** search, trending and pasted links via YouTube's InnerTube player API (the
  NewPipe / yt-dlp approach), played through our own pipeline so the sub works and there are
  no ads. SponsorBlock segments are skipped (toggle in Settings). Client identities are tried
  in order (visionOS, then iOS); update them from yt-dlp when YouTube moves.
- **NAS:** browse and play straight off a share, no media server needed. SMB goes through
  AMSMB2 (libsmb2) and a loopback HTTP server inside the app, WebDAV through
  PROPFIND with a fallback to scraping plain HTTP directory indexes. Credentials live in the
  Keychain. NAS files always use the FFmpeg backend.
- **VR video:** 180° and 360° equirectangular (mono, or stereo via SBS/TAB halves) wrapped on
  a sphere around you on the Vision Pro, detected from file names with a per-file override.
- **Comfort & playback:** recentre on your current head pose (ARKit device anchor; use it
  lying down), screen placement remembered, resume where you left off with progress synced to
  Jellyfin (Continue Watching) and Plex (On Deck), external subtitles from both servers,
  picture controls and HDR boost on the cinema screen, room dimming, autoplay next, sleep
  timer, recent items.
- **Two devices, one sub:** receiver accepts both and follows whichever is sending.

## Wire protocol

47-byte BLE packets, write-without-response:

```
0      uint8   magic 0xB5
1..2   uint16  sequence (LE)
3..6   uint32  timestamp ms since stream start (LE)
7..46  int16   × 20  mono samples @ 1 kHz (LE)
```

2 kB/s. Config characteristic: `uint16 extraDelayMs, uint8 mute`. Status notify every 500 ms:
`uint16 bufferFill, uint16 droppedPackets, uint16 underruns`.

## Building the app

**GitHub Actions (no Mac needed).** Every push to `main` runs `.github/workflows/build.yml` and
uploads `BassPlayer-<version>-visionos-unsigned.ipa` and `BassPlayer-<version>-tvos-unsigned.ipa`
as workflow artifacts; a `vX.Y.Z` tag attaches them, and the firmware, to a GitHub release.
This works in a fork too: turn Actions on in the fork and run "Build unsigned IPAs". The FFmpeg
libraries are downloaded from this repository's releases and checked against
`Vendor/FFmpegKit/checksums.json`.

**On a Mac.** These are the steps the workflow runs; the author has no Mac, so they have not
been tried by hand. You need Xcode with the visionOS 26 (or later) SDK; CI uses Xcode 27.

```
brew install xcodegen
git clone https://github.com/muzam2/vision-bass-player && cd vision-bass-player
bash Vendor/FFmpegKit/tools/fetch_binaries.sh   # about 170 MB of FFmpeg xcframeworks
xcodegen generate
open BassPlayer.xcodeproj
```

The project is set up for unsigned builds. To run from Xcode on your own device, change
`bundleIdPrefix` in `project.yml` to your own, remove the four `CODE_SIGN…` / `DEVELOPMENT_TEAM`
lines under `settings`, run `xcodegen generate` again and pick your team under Signing &
Capabilities. Schemes: `BassPlayer` (visionOS) and `BassPlayerTV` (tvOS). `BassPlayer.xcodeproj`
is generated; `project.yml` is the source of truth.

## Installing on the Vision Pro

The official iloader cannot see a Vision Pro (it has no USB port), so use the fork with
wireless Vision Pro support: [muzam2/iloader](https://github.com/muzam2/iloader/releases)
(Linux build; other systems build it from source).

1. Vision Pro: Settings → Privacy & Security → Developer Mode → On. Then open Settings →
   General → Remote Devices and leave it open; computer and headset on the same network.
2. iloader: select the Vision Pro, type the six-digit code it shows, pair (once), and sign in
   with a free Apple ID.
3. **Import IPA** → `BassPlayer-<version>-visionos-unsigned.ipa` from the
   [latest release](https://github.com/muzam2/vision-bass-player/releases/latest). It signs
   and installs over Wi-Fi; keep the headset awake until it finishes.
4. Vision Pro: Settings → General → VPN & Device Management → trust your Apple ID.

Free Apple ID limits: the signature lasts 7 days and you can have 3 sideloaded apps. Renew by
importing the IPA again (settings are kept), or install SideStore with iloader's SideStore
button so the headset renews by itself.

`tools/diag_receiver.py` on a LAN machine receives the app's diagnostics log (Settings →
Diagnostics → Send / Stream; set the receiver address there to your own machine) and can serve
an IPA to Safari on the headset for installing through SideStore.

## Installing on the Apple TV

Run atvloadly (Docker, Linux/OpenWrt) on your LAN, pair it with the Apple TV via Settings →
Remotes and Devices → Remote App and Devices, then upload the tvOS IPA. It re-signs with your free
Apple ID and keeps the signature refreshed.

## Receiver

Two supported boards, one firmware:

| Board | PlatformIO env | Notes |
|---|---|---|
| **ESP32-A1S Audio Kit** (ES8388) | `esp32-a1s` | Nothing to wire; 3.5 mm jack is line out. Power via micro-USB (5 V) or the JST battery connector. |
| Generic ESP32 + PCM5102A board | `esp32dev` | Wiring and jumpers in `src/main.cpp`. |

Flash: `cd firmware/esp32-bass-receiver && pio run -e esp32-a1s -t upload` (or `-e esp32dev`).
The [latest release](https://github.com/muzam2/vision-bass-player/releases/latest) has prebuilt
binaries for both (`bass-receiver-<env>.bin`, `bootloader-<env>.bin`, `partitions-<env>.bin`)
to flash with `esptool`; the command is in docs/SETUP-GUIDE.md. The board advertises as **BassSub**;
the app connects automatically when you open a film.

**Two devices, one sub.** The receiver accepts the Vision Pro and the Apple TV at the same time
and plays whichever one is currently sending audio. Pause on one, press play on the other, and
the sub switches over within about 1.5 s. No re-pairing.

Power the ESP32 from a clean 5 V supply (official Raspberry Pi micro-USB PSU or an Apple USB-C
brick); cheap chargers can put a whine into the line out. Both apps talk to the same receiver.

If the sub hums, power the ESP32 and the sub from the same socket strip or put a ground-loop
isolator on the RCA lead.

## Syncing bass with picture

The sub's path (Bluetooth, receiver buffer) is slower than the headset's own sound, so the app
holds its picture and sound back to match. Two settings under Settings → Subwoofer receiver:

- **Bass lead** (0–300 ms): delays the headset's sound and picture so the sub catches up.
- **Receiver delay** (0–400 ms): delays the sub, for when the thump comes early.

To set them, play `bass-sync-sweep.mp4` (from the latest release, or made with
`tools/make_bass_sync_videos.py`) with both at 0. It plays a click on the headset and a thump
on the sub, with the thump a little earlier at each step; the step where they land together is
your Bass lead. On the author's setup that was about 140 ms. `bass-sync-steady.mp4` checks the
result.

## Licence

GPL-3.0 (see `LICENSE`), because the vendored KSPlayer is GPLv3. Other vendored code keeps its
own licence: AMSMB2 / libsmb2 (LGPL-2.1), edge264 (BSD), FFmpeg and its dependencies (see
`Vendor/FFmpegKit`).
