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
| `BassPlayer/Jellyfin` | Minimal Jellyfin client (sign-in, movie list, stream URL) |
| `BassPlayer/Player` | `PlayerController` (AVPlayer, phase 1) + `PlayerView` |
| `BassPlayer/Audio` | `BassExtractor` (LPF → 1 kHz Int16 packets) and `BassTapProcessor` (MTAudioProcessingTap glue) |
| `BassPlayer/BLE` | `BassLink` CoreBluetooth central |
| `BassPlayer/Views` | Library, settings, status ornament |
| `firmware/esp32-bass-receiver` | PlatformIO project for the ESP32 receiver |
| `.github/workflows/build.yml` | Builds the unsigned IPA on a macOS runner |

## Phase plan

1. **Now:** AVPlayer backend. Plays MP4/MOV with H.264/HEVC + AAC/AC‑3/E‑AC‑3 directly; anything
   else (MKV, DTS, TrueHD…) is remuxed/transcoded by Jellyfin to MP4 on the fly. Bass tap, BLE
   link and receiver are complete.
2. **Next:** swap the backend for [KSPlayer](https://github.com/kingslay/KSPlayer) (FFmpeg) so
   MKV/DTS/TrueHD direct-play, and feed `BassExtractor` from an `AVAudioEngine` tap. Same
   `BassExtractor` and `BassLink`, no firmware change.
3. **Later:** ImmersiveSpace screen (tilt / curve / giant cinema) by pushing decoded frames
   into a RealityKit texture.

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

Parts: ESP32 dev board, PCM5102A I²S DAC board, 3.5 mm→RCA cable, USB power.

Wiring and jumper settings are in `firmware/esp32-bass-receiver/src/main.cpp`. Flash with
PlatformIO: `cd firmware/esp32-bass-receiver && pio run -t upload`. The board advertises as
**BassSub**; the app connects automatically when you open a film.

If the sub hums, power the ESP32 and the sub from the same socket strip or put a ground-loop
isolator on the RCA lead.

## Syncing bass with picture

Settings → *Extra delay* adds 0–400 ms on the receiver. Start at 0; if the thump lands
*before* the explosion, increase it. (Phase 2 measures round-trip and sets this automatically.)
