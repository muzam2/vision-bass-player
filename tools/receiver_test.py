#!/usr/bin/env python3
"""Test the ESP32 bass receiver from a computer, without the headset or Apple TV.

  bootlog  reset the board over USB serial and print what it says (expects the two lines
           "[codec] ES8388 init ok" and "[boot] BassSub advertising")
  scan     look for the BassSub Bluetooth LE advertisement
  tone     play a sine through the sub (packets in the app's wire format)
  thumps   play a kick-drum pattern through the sub

Needs:  pip install pyserial bleak      (pyserial for bootlog, bleak for the rest)

Run:    python tools/receiver_test.py bootlog --port COM3
        python tools/receiver_test.py scan
        python tools/receiver_test.py tone --freq 40 --level 9000 --seconds 4
        python tools/receiver_test.py thumps --level 18000 --bars 12 --delay 80

--level is the peak sample value out of 32767. Start low (3000) on an unknown sub.
--delay is the receiver's extra buffer in ms (the app's "Receiver delay"); it is set back
to 0 when the run ends. The wire protocol here must stay in sync with BassLink.swift,
BassExtractor.swift and firmware/esp32-bass-receiver/src/main.cpp.
"""
import argparse
import asyncio
import math
import struct
import sys
import time

DEVICE_NAME = "BassSub"
SVC_UUID = "7a3b0001-2c4d-4e5f-8a9b-0c1d2e3f4a5b"
AUDIO_UUID = "7a3b0002-2c4d-4e5f-8a9b-0c1d2e3f4a5b"
CONFIG_UUID = "7a3b0003-2c4d-4e5f-8a9b-0c1d2e3f4a5b"
STATUS_UUID = "7a3b0004-2c4d-4e5f-8a9b-0c1d2e3f4a5b"

PKT_MAGIC = 0xB5
SAMPLES_PER_PKT = 20          # 20 ms of audio at 1 kHz
PKT_INTERVAL = 0.020
EXPECTED_LINES = ("[codec] ES8388 init ok", "[boot] BassSub advertising")


# ---------- serial ----------
def bootlog(port: str, seconds: float) -> int:
    import serial

    ser = serial.Serial()
    ser.port = port
    ser.baudrate = 115200
    ser.timeout = 0.1
    ser.dtr = False               # asserted DTR would hold IO0 low (download mode)
    ser.rts = False
    ser.open()
    ser.rts = True                # pulse EN low: the same hard reset esptool does
    time.sleep(0.1)
    ser.reset_input_buffer()
    ser.rts = False

    buf = bytearray()
    end = time.time() + seconds
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            buf.extend(chunk)
    ser.close()

    text = buf.decode("utf-8", errors="backslashreplace")
    sys.stdout.write(text)
    print(f"\n--- {len(buf)} bytes in {seconds:.0f} s ---")
    ok = True
    for line in EXPECTED_LINES:
        seen = line in text
        ok &= seen
        print(f"{'seen   ' if seen else 'MISSING'}  {line}")
    boots = text.count("entry 0x")
    if boots > 1:
        ok = False
        print(f"REBOOT LOOP: the board started {boots} times in {seconds:.0f} s")
    return 0 if ok else 1


# ---------- signals (1 kHz mono int16) ----------
def tone_samples(freq: float, level: int, seconds: float) -> list:
    fade = 0.15                   # fade in and out so the tone doesn't click
    out = []
    for i in range(int(seconds * 1000)):
        t = i / 1000.0
        env = min(1.0, t / fade, (seconds - t) / fade)
        out.append(int(level * env * math.sin(2 * math.pi * freq * t)))
    return out + [0] * 500


def thump(t: float) -> float:
    # Pitch drops 90 -> 40 Hz in the first ~100 ms, level decays over ~300 ms.
    if t < 0 or t > 0.45:
        return 0.0
    phase = 2 * math.pi * (40 * t + 50 * 0.04 * (1 - math.exp(-t / 0.04)))
    return min(1.0, t / 0.004) * math.exp(-t / 0.10) * math.sin(phase)


def thump_samples(level: int, bars: int) -> list:
    bar = 2.4                     # seconds: four beats at 100 BPM
    starts = [b * bar + h for b in range(bars) for h in (0.0, 0.6, 1.2, 1.5)]
    out = []
    for i in range(int((bars * bar + 0.6) * 1000)):
        t = i / 1000.0
        v = sum(thump(t - s) for s in starts if 0 <= t - s <= 0.45)
        out.append(max(-32767, min(32767, int(level * v))))
    return out


# ---------- BLE ----------
async def scan(timeout: float) -> int:
    from bleak import BleakScanner

    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    hits = 0
    for addr, (dev, adv) in found.items():
        name = adv.local_name or dev.name or ""
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        if DEVICE_NAME in name or SVC_UUID in uuids:
            hits += 1
            print(f"FOUND name={name!r} addr={addr} rssi={adv.rssi} service={'yes' if SVC_UUID in uuids else 'no'}")
    print(f"devices seen: {len(found)}, {DEVICE_NAME} matches: {hits}")
    return 0 if hits else 1


async def play(samples: list, delay_ms: int) -> int:
    from bleak import BleakClient, BleakScanner

    dev = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=12.0)
    if dev is None:
        print(f"{DEVICE_NAME} not found. Is the board powered?")
        return 1

    statuses = []                 # (bufferFill, droppedPackets, underruns); counters are since power-on
    async with BleakClient(dev) as client:
        print(f"connected, mtu {client.mtu_size}")
        await client.start_notify(STATUS_UUID, lambda _, d: statuses.append(struct.unpack("<HHH", bytes(d))))
        await client.write_gatt_char(CONFIG_UUID, struct.pack("<HB", delay_ms, 0), response=True)

        loop = asyncio.get_running_loop()
        t0 = loop.time()
        packets = len(samples) // SAMPLES_PER_PKT
        for seq in range(packets):
            chunk = samples[seq * SAMPLES_PER_PKT:(seq + 1) * SAMPLES_PER_PKT]
            pkt = struct.pack("<BHI", PKT_MAGIC, seq & 0xFFFF, seq * SAMPLES_PER_PKT) + struct.pack("<20h", *chunk)
            await client.write_gatt_char(AUDIO_UUID, pkt, response=False)
            wait = t0 + (seq + 1) * PKT_INTERVAL - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
        played = loop.time() - t0
        during = list(statuses)   # the stream ending always adds one underrun; don't count it
        await asyncio.sleep(1.0)
        await client.write_gatt_char(CONFIG_UUID, struct.pack("<HB", 0, 0), response=True)

    print(f"packets sent: {packets} over {played:.1f} s, peak level {max(abs(s) for s in samples)}/32767")
    if not during:
        print("no status reports received")
        return 1
    fills = [s[0] for s in during if s[0] > 0]
    dropped = during[-1][1] - during[0][1]
    underruns = during[-1][2] - during[0][2]
    print(f"buffer fill min/max: {min(fills) if fills else 0}/{max(fills) if fills else 0} ms "
          f"(target {60 + delay_ms}), dropped: {dropped}, underruns while playing: {underruns}")
    return 0 if dropped == 0 and underruns == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("bootlog", help="reset the board and print its serial output")
    p.add_argument("--port", required=True, help="e.g. COM3 or /dev/ttyUSB0")
    p.add_argument("--seconds", type=float, default=10.0)

    p = sub.add_parser("scan", help="look for the BassSub advertisement")
    p.add_argument("--seconds", type=float, default=8.0)

    p = sub.add_parser("tone", help="play a sine through the sub")
    p.add_argument("--freq", type=float, default=40.0)
    p.add_argument("--level", type=int, default=3000)
    p.add_argument("--seconds", type=float, default=4.0)
    p.add_argument("--delay", type=int, default=0)

    p = sub.add_parser("thumps", help="play a kick-drum pattern through the sub")
    p.add_argument("--level", type=int, default=9500)
    p.add_argument("--bars", type=int, default=4, help="2.4 s each")
    p.add_argument("--delay", type=int, default=0)

    a = ap.parse_args()
    if a.cmd == "bootlog":
        return bootlog(a.port, a.seconds)
    if a.cmd == "scan":
        return asyncio.run(scan(a.seconds))
    if not 0 < a.level <= 32767:
        ap.error("--level must be 1..32767")
    if not 0 <= a.delay <= 2000:
        ap.error("--delay must be 0..2000 ms")
    if a.cmd == "tone":
        if not 0 < a.freq <= 200:
            ap.error("--freq must be 1..200 Hz (the stream is sampled at 1 kHz)")
        return asyncio.run(play(tone_samples(a.freq, a.level, a.seconds), a.delay))
    return asyncio.run(play(thump_samples(a.level, a.bars), a.delay))


if __name__ == "__main__":
    sys.exit(main())
