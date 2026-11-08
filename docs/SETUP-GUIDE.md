# Bass Player — the idiot's guide

From empty box to bass in the room, in order. Do the steps top to bottom; each one assumes the
previous ones are done. Expect about two evenings: one for hardware and flashing, one for
installing the apps and tuning.

---

## 0. What you're building

```
Jellyfin or Plex ──Wi‑Fi──▶ Vision Pro / Apple TV app ──Bluetooth LE──▶ ESP32 box ──RCA──▶ powered sub
                                     │
                                     └──▶ AirPods / audio pods / TV sound (everything else)
```

The app plays the film, keeps all the sound on the headset (or TV), and sends only the deep
bass to a tiny Bluetooth receiver wired to your sub.

---

## 1. Shopping list

| Item | Why | Rough UK price |
|---|---|---|
| **ESP32-A1S Audio Kit** (AI-Thinker, ES8388 version) | The receiver. Has the DAC built in. | £12–15 |
| **Raspberry Pi official micro-USB power supply** (5.1 V 2.5 A) | Clean 5 V for the ESP32. Cheap chargers hum. | £8 |
| **3.5 mm stereo jack → 2× RCA cable** (1–3 m) | ESP32 line out → sub input | £5 |
| **Ground-loop isolator** (3.5 mm or RCA) | Only if the sub hums once connected. Buy later if needed. | £8 |
| Micro-USB **data** cable | For flashing. Some charging cables have no data wires. | £3 |
| A computer (Windows/Linux/Mac) on the same Wi‑Fi as the headset | For flashing and sideloading | — |

Already have: Apple Vision Pro and/or Apple TV 4K, a powered subwoofer with an RCA/line input,
a Jellyfin or Plex server with your films.

**Which ESP32-A1S?** Listings say "ESP32-Audio-Kit" or "ESP32-A1S". Make sure the photos show
an **ES8388** chip near the headphone jack (the older AC101 version isn't supported).

---

## 2. Flash the receiver

You only do this once.

1. Install **Python 3** if you don't have it, then in a terminal:
   `pip install esptool`
2. Go to the GitHub repo → **Actions** → the latest green "Build ESP32 firmware" run → download
   the **`firmware-esp32-a1s`** artifact and unzip it. You get three `.bin` files.
3. Plug the A1S into the computer with the **data** micro-USB cable, using the USB port
   nearest the two small buttons (that's the serial one; the other port is power only).
4. Find the port: Windows → Device Manager → Ports (e.g. `COM5`); Linux → `ls /dev/ttyUSB*`;
   Mac → `ls /dev/cu.usb*`.
5. Flash (replace `COM5` with your port):
   ```
   esptool --chip esp32 --port COM5 --baud 460800 write_flash \
     0x1000  bootloader-esp32-a1s.bin \
     0x8000  partitions-esp32-a1s.bin \
     0x10000 bass-receiver-esp32-a1s.bin
   ```
   If it says "Failed to connect", hold the **BOOT** button on the board while it retries.
6. Optional check: `pio device monitor -p COM5 -b 115200` (or any serial monitor) should show
   `[codec] ES8388 init ok` and `[boot] BassSub advertising`.

> Prefer building yourself? `pip install platformio`, then in `firmware/esp32-bass-receiver`:
> `pio run -e esp32-a1s -t upload`.

---

## 3. Wire the receiver to the sub

1. Plug the 3.5 mm end of the cable into the A1S **headphone/line jack**.
2. Plug the RCA ends into the sub's **LFE** or **Line In** (left or right if it only has one).
3. Turn the sub's **gain/volume knob down to about a quarter**. The A1S output is fairly hot.
4. Set the sub's **crossover/low-pass** knob to its highest setting or "LFE/bypass". The app
   already filters everything above 120 Hz; a second filter just makes the bass quieter.
5. Power the A1S from the Raspberry Pi supply, plugged into the **same socket strip as the sub**.
6. Nothing should hum yet. If it does, the ground-loop isolator goes in the 3.5 mm→RCA path.

---

## 4. Install the app on the Vision Pro (no Mac needed)

1. **Turn on Developer Mode** on the headset: Settings → Privacy & Security → Developer Mode →
   On. (If it's not there yet, finish step 3 below first, it appears after the first pairing.)
2. On your computer, download the **iloader** build with Vision Pro support (see the README link),
   run it, and allow it to find devices on the local network.
3. On the headset open Settings → General → **Remote Devices**. Leave that screen open. In
   iloader, click your Vision Pro → **Pair** → type the code the headset shows.
4. In iloader install **SideStore** onto the headset and sign in with a free Apple ID (a burner
   Apple ID is fine and arguably better).
5. On the headset, install **LocalDevVPN** from the App Store and turn its VPN on. SideStore
   needs it to refresh apps by itself.
6. Get the app: GitHub repo → Actions → latest green "Build unsigned IPAs" → download
   **`BassPlayer-visionos-unsigned-ipa`**, unzip, and either drag the `.ipa` into iloader or
   AirDrop/open it in SideStore on the headset. SideStore signs it with your Apple ID.
7. First launch: Settings → General → VPN & Device Management → trust your Apple ID.

Free Apple ID rules: the signature lasts 7 days (SideStore renews it in the background while the
VPN is on), and you can have 3 sideloaded apps at once.

---

## 5. Install the app on the Apple TV

1. On a Linux box, NAS or router that is always on, run **atvloadly** (Docker image
   `bitxeno/atvloadly`). Its README has a one-line `docker run`.
2. Apple TV: Settings → Remotes and Devices → **Remote App and Devices**. Leave it open.
3. Open atvloadly's web page, pick the Apple TV, enter the pairing code.
4. Download **`BassPlayer-tvos-unsigned-ipa`** from the same Actions run, unzip, upload the
   `.ipa` in atvloadly with your Apple ID. It re-signs it every week automatically.
5. On the Apple TV: Settings → General → Privacy & Security → trust the developer profile.

---

## 6. Connect your media server

Open Bass Player → gear icon (top right).

**Jellyfin:** enter the server address (`http://192.168.x.x:8096`), username and password →
Sign in. Your movies (and episodes if you enable them under Playback) appear.

**Plex:** tap **Sign in with plex.tv**. A 4-letter code appears. On your phone go to
**plex.tv/link**, enter the code. Within ~10 s the app shows your servers; pick one.

Leave **Backend** on **FFmpeg (all formats)**. That plays MKV, DTS, TrueHD, FLAC, AV1, HDR10,
HLG and Dolby Vision profile 8 straight from the original file. (AVPlayer mode is only there
as a fallback and relies on the server transcoding to MP4.)

---

## 7. First play

1. Power the A1S. Its serial log (if attached) says `advertising`.
2. In the app, pick a film. The player opens and the status chip top-right should go
   **green: "Bass tap · 48000 Hz · 6 ch"** (or 2 ch) within a few seconds.
3. The bottom strip should say **Sub connected**. If it says Off, tap **Connect sub**; the first
   time visionOS/tvOS asks for Bluetooth permission → Allow.
4. Find an explosion. You should feel it.

If nothing: see Troubleshooting at the bottom.

---

## 8. Tuning the timing (the bit that matters)

Bass that arrives late feels wrong even when you can't hear why. Two knobs in Settings →
Subwoofer receiver:

| Symptom | Fix |
|---|---|
| Thump lands **before** the picture/sound | Raise **Receiver delay** in 10 ms steps |
| Thump lands **after** | Raise **Bass lead** in 10 ms steps (FFmpeg backend only). This holds the headset's own audio and picture back by that much so the sub catches up. |
| Can't tell | Use a film with a clean single hit (a door slam, a drum) and loop it. Start with **Bass lead 80 ms**, which is roughly the BLE link, then nudge. |

Typical result: Bass lead 60–100 ms, Receiver delay 0. Once set it stays set; both values are
remembered per device, so tune the Apple TV separately (it has its own audio latency).

**Level:** set the sub's gain so bass is felt, not heard as a separate boom. If the receiver's
line out clips (fuzzy, distorted thumps), turn the sub gain **up** and ask me to drop the DAC
output level a few dB in firmware.

**Diagnostics** (Settings → Diagnostics): "Packets dropped" should stay near 0, "Receiver
buffer" should sit around 60–80 samples and not drift, "Underruns" should not climb while
playing. If buffer drifts steadily, the receiver's drift control isn't keeping up; tell me.

---

## 9. Using two devices with one sub

Nothing to configure. The receiver accepts both the Vision Pro and the Apple TV at once and
plays whichever one is **currently sending**. Pause on one, press play on the other, and the sub
follows within about 1.5 s.

---

## 10. The immersive cinema screen (Vision Pro)

In the player, the bottom bar has **Cinema screen**. Tap it: the room goes black and a large
screen appears 3 m in front of you.

- **Move it:** pinch-and-drag the screen. Up/down and nearer/further as expected; sideways
  swings it around you.
- **Resize:** pinch with both hands and spread.
- **Tilt:** two-hand rotate. For lying in bed, tilt it so the top leans away and raise Height.
- **Fine control:** the slider icon next to the button opens Width / Distance / Height /
  Tilt / Curve sliders and a Reset.
- **Picture upside down?** Toggle **Flip vertically** once; it's remembered.
- **Full immersion** is on by default (black everywhere, nothing of the room). Turn it off to
  keep the black dome but see your hands via passthrough.
- **HDR output** on by default. If HDR films look washed out or too dark on the big screen,
  toggle it off and tell me which film; that's a colour-space tweak on my side.

The audio and the bass link are unaffected by the screen; it only changes where the picture is.

---

## 10b. 3D films

Nothing to set up. The library badge shows what was detected (e.g. "3D Half SBS"). If a 3D
rip isn't detected, or detected wrongly, use the **3D** menu in the player to pick the packing.

- On the **flat window** and on **Apple TV** you see one eye, correctly proportioned.
- On the Vision Pro **cinema screen** you get real 3D. If depth looks inverted (things pop the
  wrong way), the file is probably right-eye-first: pick the other half/full variant and tell
  me; a left/right swap toggle is a one-line addition.
- **Apple spatial videos / MV-HEVC** (iPhone 15 Pro+, Vision Pro recordings, Apple TV+ 3D)
  play 3D on the cinema screen too, via Apple's own pipeline.
- **Blu-ray 3D ISOs / MVC MKVs** play as 2D for now. To get them in 3D, convert once to
  half-SBS on your server: on Linux, `mvctools` from https://github.com/brunoga/bdtools
  (`mvctools convert disc.iso out.mkv` keeps audio and subtitles); on Windows with an Intel
  iGPU, BD3D2MK3D (uses FRIM). Native MVC playback in the app is on the roadmap.

## 10c. Play straight off the NAS (no media server)

Source switch → **NAS** → **+**. Two kinds:

- **SMB** (Synology, QNAP, TrueNAS, Windows shares): address `nas.local` or `192.168.1.20`
  lists the shares; `192.168.1.20/video` opens one share directly. Username/password as for
  the NAS; leave blank for guest. The first time, visionOS/tvOS asks for Local Network access
  → Allow.
- **WebDAV / HTTP**: the full URL of the WebDAV folder (Synology: `https://nas:5006/video`),
  or any web server folder with directory listing turned on.

Then browse folders and tap a video. Everything the FFmpeg backend plays from Jellyfin plays
here too (MKV, DTS, HDR, 3D by file name). Blu-ray ISOs don't play; use MakeMKV first.

## 10d. YouTube

Pick **YouTube** in the library's source switch. Trending loads by default; the search box
searches, and a pasted link or video id plays directly. Streams are fetched from YouTube's
player API at play time, so there are no ads; SponsorBlock skips sponsor segments (Settings →
YouTube to turn off). The sub works exactly as with films.

If YouTube suddenly stops playing ("no playable streams"), YouTube changed something on their
side; the fix is updating the client identities in `InnerTubeClient.swift` from yt-dlp.

## 11. Troubleshooting

| Problem | Check |
|---|---|
| Sub never shows "connected" | Is the A1S powered and showing `advertising` on serial? Bluetooth permission granted to the app? Only two devices can be connected; power-cycle the A1S to clear stale ones. |
| Connected, chip green, no bass | Sub gain up? Cable in the headphone jack, not the mic jack? Sub crossover at max? Try **Mute sub** off/on. |
| Status chip stays "Bass tap off" | Backend is AVPlayer and the stream is HLS/transcoding; switch Backend to FFmpeg. |
| Hum from the sub | Same socket strip for both; then ground-loop isolator on the RCA lead; then try battery power on the A1S (JST connector). |
| Film won't open (FFmpeg) | Jellyfin: check the user has access to the library. Plex: the chosen server connection might be a remote relay; pick the server again from Settings when on the same LAN. |
| App vanished after a week | SideStore's refresh failed: open SideStore, make sure LocalDevVPN is on, tap Refresh. On Apple TV check atvloadly is still running. |
| Bass stutters | Keep the A1S within ~5 m line-of-sight of the headset; move it away from the Wi‑Fi router; check "Packets dropped" in Diagnostics. |
| `ES8388 init FAILED` on serial | You have the AC101 variant of the A1S. Build the `esp32dev` firmware and use a £6 PCM5102A board instead (wiring in `src/main.cpp`). |

---

## 12. Updating

Every push to the repo builds fresh IPAs and firmware in Actions. Reinstall the `.ipa` the same
way as before (SideStore keeps your settings); reflash the firmware only when the firmware
artifact changes.
