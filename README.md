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
free Apple ID: SideStore / iloader for the Vision Pro (wireless pairing, no dev strap),
[atvloadly](https://github.com/bitxeno/atvloadly) for the Apple TV. Both talk to the same ESP32
receiver, so one sub serves the headset and the TV.

## Repo layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec with two targets, `BassPlayer` (visionOS) and `BassPlayerTV` (tvOS), sharing all sources |
| `BassPlayer/App` | SwiftUI app entry, audio session |
| `BassPlayer/Media` | `MediaItem` model shared by both servers, `LibraryStore` (source/backend settings) |
| `BassPlayer/Jellyfin`, `BassPlayer/Plex` | Server clients |
| `BassPlayer/Player` | `FFmpegPlayerView` (KSPlayer) and the AVPlayer fallback |
| `BassPlayer/Audio` | `BassExtractor` (LPF → 1 kHz Int16 packets), `BassEngineTap` (AVAudioEngine tap + lead delay), `BassTapProcessor` (MTAudioProcessingTap glue for AVPlayer) |
| `BassPlayer/Immersive` | RealityKit cinema screen (visionOS only) |
| `docs/SETUP-GUIDE.md` | Step-by-step hardware, install and tuning guide |
| `BassPlayer/BLE` | `BassLink` CoreBluetooth central |
| `BassPlayer/Views` | Library, settings, status ornament |
| `firmware/esp32-bass-receiver` | PlatformIO project for the ESP32 receiver |
| `.github/workflows/build.yml` | Builds the unsigned IPA on a macOS runner |

## Status

Everything is built; what remains is on-device testing and tuning. See **docs/SETUP-GUIDE.md**
for the step-by-step setup.

- **Playback:** [KSPlayer](https://github.com/kingslay/KSPlayer) (GPLv3 branch, FFmpeg 6.1) is
  the default backend. Direct-plays MKV/MP4/MOV/TS/AVI with H.264, HEVC, AV1, VP9, ProRes and
  more; audio AAC, AC‑3, E‑AC‑3, DTS, DTS‑HD, TrueHD, FLAC, Opus; HDR10, HLG and Dolby Vision
  profile 8 passed to the display. Hardware decoding via VideoToolbox. AVPlayer remains as a
  fallback backend (MP4 only; Jellyfin remuxes for it).
- **Servers:** Jellyfin (username/password) and Plex (plex.tv PIN sign-in, server discovery,
  per-server tokens). Both map into one `MediaItem` model; movies and TV episodes.
- **Bass:** with the FFmpeg backend the tap sits on KSPlayer's `AVAudioEngine` mixer, picking
  the LFE channel for 5.1/7.1 tracks. A "Bass lead" setting inserts an `AVAudioUnitDelay`
  before the output and delays video by the same amount, so the sub's BLE latency is cancelled.
- **Immersive screen (visionOS):** RealityKit cinema screen fed from the decoder's pixel
  buffers via a `DrawableQueue` (CoreImage does YUV→RGB and HDR). Flat or curved mesh, drag /
  pinch / rotate gestures plus sliders, 200 m black dome so there are no edge artifacts in
  either lens, full immersion by default.
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

## Building the app (CI)

Every push to `main` runs `.github/workflows/build.yml` and uploads
`BassPlayer-<version>-visionos-unsigned.ipa` and `BassPlayer-<version>-tvos-unsigned.ipa` as
workflow artifacts. Tag `vX.Y.Z` to attach it to a
GitHub release.

## Installing on the Vision Pro

1. Vision Pro: Settings → Privacy & Security → Developer Mode → On.
2. On a machine on the same Wi‑Fi, run an iloader build with Vision Pro support (or an
   atvloadly-style service built on [idevice](https://github.com/jkcoxson/idevice)); pair via
   Settings → General → Remote Devices on the headset.
3. Install SideStore, sign in with a free Apple ID, then install the IPA from the Actions
   artifact. Free-ID limits: 7-day signature (SideStore refreshes it), 3 apps max.

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
CI also builds both and uploads `firmware-<env>` artifacts (`firmware.bin` + bootloader +
partitions) you can flash with `esptool` or the web flasher. The board advertises as **BassSub**;
the app connects automatically when you open a film.

**Two devices, one sub.** The receiver accepts the Vision Pro and the Apple TV at the same time
and plays whichever one is currently sending audio. Pause on one, press play on the other, and
the sub switches over within about 1.5 s. No re-pairing.

Power the ESP32 from a clean 5 V supply (official Raspberry Pi micro-USB PSU or an Apple USB-C
brick); cheap chargers can put a whine into the line out. Both apps talk to the same receiver.

If the sub hums, power the ESP32 and the sub from the same socket strip or put a ground-loop
isolator on the RCA lead.

## Syncing bass with picture

Settings → *Extra delay* adds 0–400 ms on the receiver. Start at 0; if the thump lands
*before* the explosion, increase it. (Phase 2 measures round-trip and sets this automatically.)
