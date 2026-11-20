# Receiver bring-up record (2026-11-20)

First power-on of the ESP32-A1S receiver, done from the owner's Windows PC. Read this before
touching `firmware/` again: it has the crash that the first CI image hit, why, the fix, and
what has and hasn't been tested on real hardware.

## Result

The receiver works end to end as far as a PC can test it. On the fixed firmware the board
boots, advertises as BassSub, accepts audio in the app's wire format over BLE, and plays it
through the 3.5 mm jack into the owner's powered sub. The owner heard the test tones and thumps.

**Not tested yet:** the Vision Pro or Apple TV as the sender (the real app's `BassLink`), two
devices at once, and timing against picture.

## Hardware as found

| Item | Value |
|---|---|
| Board | AI-Thinker ESP32-A1S Audio Kit, ES8388 codec (codec answers at I²C 0x10) |
| Chip | ESP32-D0WD-V3, revision v3.1, 40 MHz crystal |
| Flash | 4 MB (manufacturer `a1`, device `4016`) |
| USB-serial | Silicon Labs CP2102 (`USB\VID_10C4&PID_EA60`), COM3 on the owner's PC |

Windows had no driver for the CP2102 (Device Manager error code 28). The owner installed the
Silicon Labs CP210x Universal Windows Driver by hand. esptool's auto-reset works on this board;
no BOOT or RST presses were needed.

## The crash

CI run 42438883636 built a merged image (`bass-receiver-esp32-a1s-merged.bin`, 923,920 bytes,
SHA-256 `c63d0e2b…24ecf56e`). It flashed and verified, then reboot-looped about every 0.6 s.
`[codec] ES8388 init ok` printed on every boot; `[boot] BassSub advertising` never did.

First cycle as received at 115200 baud, with the ROM loader lines between `rst:` and `entry`
trimmed. The `VW\x81` is what arrived, probably a serial glitch just after reset:

```
rst:0x1 (POWERON_RESET),boot:0x1f (SPI_FAST_FLASH_BOOT)
...
entry 0x4008059c
E (373) esp_core_dump_flash: Core VW\x81data check failed:
Calculated checksum='d31bc922'
Image checksum='ffffffff'
[codec] ES8388 init ok
ESP_ERROR_CHECK failed: esp_err_t 0x103 (ESP_ERR_INVALID_STATE) at 0x400d8b0d
file: ".pio/libdeps/esp32-a1s/NimBLE-Arduino/src/NimBLEDevice.cpp" line 880
func: static void NimBLEDevice::init(const std::string&)
expression: esp_bt_controller_init(&bt_cfg)

abort() was called at PC 0x40093c8f on core 1

Backtrace: 0x40093d2c:0x3ffb1f40 0x40093cf1:0x3ffb1f60 0x40099c85:0x3ffb1f80 0x40093c8f:0x3ffb2000 0x400d8b0d:0x3ffb2030 0x400d2122:0x3ffb20b0 0x40115795:0x3ffb2120 0x40094da9:0x3ffb2150

ELF file SHA256: 7f545dc67

Rebooting...
```

The core-dump checksum error only appears on the first boot after a flash (blank core-dump
region) and is harmless.

## Cause

`platformio.ini` has `platform = espressif32` with no version, and it now resolves to **8.0.0**:
Arduino core 3.3.x on ESP-IDF v5.5.5. The CI image's app descriptor reports `idf_ver v5.5.5`,
and a local build on the PC pulled the same platform plus NimBLE-Arduino **1.4.3**.

In that core, `initArduino()` (`cores/esp32/esp32-hal-misc.c`) frees the Bluetooth controller
memory for BLE and for Classic unless something says they are in use:

```c
if (!bleInUse() && !(userOverriddenBtInUse && btInUse())) {
  btMemRelease(BT_MODE_BLE);
}
```

`bleInUse()` returns `_bleLibraryInUse`, a flag that BLE libraries set by including
`esp32-hal-alloc-ble-mem.h` (it holds a constructor that runs before `app_main`). NimBLE-Arduino
1.4.3 predates this. Its old trick, calling `btStarted()` so that `esp32-hal-bt.c` links, no
longer has any effect, and it sits behind `CONFIG_ENABLE_ARDUINO_DEPENDS` anyway. So the memory
is gone before `setup()` runs. NimBLE's own `esp_bt_controller_mem_release(CLASSIC_BT)` on line
868 is unchecked, and the first checked call, `esp_bt_controller_init()` on line 880, returns
`ESP_ERR_INVALID_STATE`.

A CI build cannot catch this. It compiles and links cleanly and only fails at boot.

## Fix

`firmware/esp32-bass-receiver/src/main.cpp` includes the registration header itself:

```cpp
#if __has_include(<esp32-hal-alloc-ble-mem.h>)
#include <esp32-hal-alloc-ble-mem.h>
#endif
```

The guard keeps older cores building; they don't have the header and don't need it. Both
`esp32-a1s` and `esp32dev` build. Commit `142122c` on branch `fix/a1s-ble-controller-memory`.

Keep the include when bumping NimBLE-Arduino or the platform, until NimBLE registers on its
own. The platform and library versions are still unpinned; pinning them to the pair tested
here (espressif32 8.0.0, NimBLE-Arduino 1.4.3) would stop the next silent drift.

## What was verified on the board

All from the Windows PC, with `tools/receiver_test.py` or the scripts it was distilled from.

| Check | Result |
|---|---|
| Boot log after flashing the fix | `[codec] ES8388 init ok`, `[boot] BassSub advertising`, no reboot in 10 s |
| BLE scan from the PC | `BassSub` seen with service `7A3B0001-…`, RSSI −65 to −70 dBm |
| GATT | Connects at MTU 247; audio is write-without-response, config is read/write, status is read/notify |
| Config write | Serial showed `[cfg] extraDelay=0 ms mute=0`; reads back `000000` |
| Audio, 3 s of 40 Hz | Serial showed `[ble] audio source -> handle 0`, `[audio] start`, then `[audio] underrun, rebuffering` when the stream stopped |
| Tones into the sub | 40 Hz at level 3000 and 9000, 60 Hz at 9000 (of 32767): heard by the owner |
| Thumps into the sub | 16 kicks at peak 8653, then 48 kicks at peak 16396: heard |
| Packet loss | 0 dropped in every run (150, 700, 510 and 1470 packets) |

**Buffering finding.** With the default 60 ms target the buffer sat between 40 and 104 ms and
one run logged an underrun mid-stream. With `extraDelay` 80 ms (target 140) it sat between 107
and 148 ms with no underruns over 29 s. The sender was a Windows PC with a Python BLE client,
whose packet timing is uneven, so this may not carry over to the headset. If the app's
diagnostics show underruns climbing, raise Receiver delay before suspecting the firmware.

`statDroppedPkts` and `statUnderruns` are counted since power-on and never reset, and the end
of every stream adds one underrun. Compare values within a run, not across runs.

## Repeating it

Build and flash from `firmware/esp32-bass-receiver` (PlatformIO and esptool are installed for
the owner's user on the Windows PC; the first build downloads the toolchain, about 8 minutes):

```
python -m platformio run -e esp32-a1s -t upload --upload-port COM3
```

Test without the headset:

```
python tools/receiver_test.py bootlog --port COM3
python tools/receiver_test.py scan
python tools/receiver_test.py tone --freq 40 --level 3000 --seconds 4
python tools/receiver_test.py thumps --level 18000 --bars 12 --delay 80
```

`scan`, `tone` and `thumps` were run against the board in this form. `bootlog` uses the same
serial code that captured the logs above but was not re-run after being moved into the tool,
because the board was on its own power supply by then.

The GitHub CLI is not installed on the Windows PC, so branch builds and artifact downloads
have to be triggered from the workstation or the GitHub site.
