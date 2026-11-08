// ESP32 subwoofer receiver for Bass Player (Apple Vision Pro).
//
// BLE GATT server receives 47-byte packets:
//   [0]    0xB5 magic
//   [1..2] uint16 LE sequence
//   [3..6] uint32 LE timestamp (ms since stream start)
//   [7..46] 20 × int16 LE mono samples at 1 kHz (20 ms of sub-bass, already low-passed)
//
// Samples go into a ring buffer, are upsampled ×8 to 8 kHz with linear interpolation and
// pushed out over I²S to a PCM5102A DAC (line out → subwoofer). Drift between the headset's
// audio clock and this crystal is absorbed by nudging the buffer level back to target.
//
// Two board targets (select in platformio.ini):
//   env:esp32dev   generic ESP32 + PCM5102A purple board
//                  BCK→GPIO26  LRCK→GPIO25  DIN→GPIO22  SCK→GND  XSMT→GPIO21  VIN→3V3
//                  Board jumpers: FLT=L, DEMP=L, XSMT=H(or GPIO), FMT=L (I²S)
//   env:esp32-a1s  AI-Thinker ESP32-A1S Audio Kit (ES8388 codec, 3.5 mm jack = line out)
//                  Nothing to wire; codec is on-board. PA (speaker amp) is left disabled.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <driver/i2s.h>
#ifdef BOARD_A1S
#include <Wire.h>
#endif

// ---------- Pins ----------
#ifdef BOARD_A1S
static const int PIN_MCLK = 0;
static const int PIN_BCK  = 27;
static const int PIN_LRCK = 25;
static const int PIN_DIN  = 26;      // ESP32 → codec DSDIN
static const int PIN_I2C_SDA = 33;
static const int PIN_I2C_SCL = 32;
static const int PIN_PA_EN = 21;     // NS4150 speaker amp enable; keep LOW
static const uint8_t ES8388_ADDR = 0x10;
#else
static const int PIN_BCK  = 26;
static const int PIN_LRCK = 25;
static const int PIN_DIN  = 22;
static const int PIN_XSMT = 21;
#endif

// ---------- Stream constants ----------
static const uint32_t IN_RATE        = 1000;     // Hz, from the headset
#ifndef OUT_RATE
#define OUT_RATE 8000                            // Hz, to the DAC (PCM5102A minimum)
#endif
static const int      UPSAMPLE       = OUT_RATE / IN_RATE;
static const int      SAMPLES_PER_PKT = 20;
static const int      PKT_HEADER     = 7;
static const int      PKT_SIZE       = PKT_HEADER + SAMPLES_PER_PKT * 2;
static const uint8_t  PKT_MAGIC      = 0xB5;

// ---------- Buffering ----------
static const int      RING_SIZE      = 8192;     // samples (8 s at 1 kHz); power of two
static const int      BASE_JITTER_MS = 60;       // minimum buffer before playing
static const int      DRIFT_TOLERANCE = 15;      // samples either side of target before nudging

// ---------- GATT UUIDs (match BassLink.swift) ----------
static const char* SVC_UUID    = "7A3B0001-2C4D-4E5F-8A9B-0C1D2E3F4A5B";
static const char* AUDIO_UUID  = "7A3B0002-2C4D-4E5F-8A9B-0C1D2E3F4A5B";
static const char* CONFIG_UUID = "7A3B0003-2C4D-4E5F-8A9B-0C1D2E3F4A5B";
static const char* STATUS_UUID = "7A3B0004-2C4D-4E5F-8A9B-0C1D2E3F4A5B";

// ---------- Shared state ----------
static int16_t  ring[RING_SIZE];
static volatile uint32_t ringHead = 0;   // written by BLE task
static volatile uint32_t ringTail = 0;   // read by audio task
static volatile uint16_t extraDelayMs = 0;
static volatile bool     muted = false;
static volatile bool     connected = false;
static volatile uint16_t statDroppedPkts = 0;
static volatile uint16_t statUnderruns = 0;
static volatile uint16_t lastSeq = 0;
static volatile bool     haveSeq = false;

static NimBLECharacteristic* statusChar = nullptr;

static inline uint32_t ringFill() { return (ringHead - ringTail) & (RING_SIZE - 1); }
static inline uint32_t targetFill() { return BASE_JITTER_MS + extraDelayMs; }

static void ringPush(int16_t s) {
  uint32_t next = (ringHead + 1) & (RING_SIZE - 1);
  if (next == ringTail) {                 // full: drop oldest so we stay near real time
    ringTail = (ringTail + 1) & (RING_SIZE - 1);
  }
  ring[ringHead] = s;
  ringHead = next;
}

static void ringReset() { ringHead = ringTail = 0; haveSeq = false; }

// ---------- BLE callbacks ----------
class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, ble_gap_conn_desc* desc) override {
    connected = true;
    ringReset();
    // 15 ms connection interval, no latency, 4 s supervision timeout.
    server->updateConnParams(desc->conn_handle, 12, 12, 0, 400);
    Serial.println("[ble] connected");
  }
  void onDisconnect(NimBLEServer* server) override {
    connected = false;
    ringReset();
    Serial.println("[ble] disconnected, advertising");
    NimBLEDevice::startAdvertising();
  }
};

class AudioCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    const std::string& v = c->getValue();
    if (v.size() != PKT_SIZE || (uint8_t)v[0] != PKT_MAGIC) return;
    const uint8_t* p = (const uint8_t*)v.data();
    uint16_t seq = p[1] | (p[2] << 8);
    if (haveSeq) {
      uint16_t expected = lastSeq + 1;
      if (seq != expected) statDroppedPkts += (uint16_t)(seq - expected);
    }
    lastSeq = seq; haveSeq = true;
    const uint8_t* s = p + PKT_HEADER;
    for (int i = 0; i < SAMPLES_PER_PKT; i++) {
      int16_t sample = (int16_t)(s[2 * i] | (s[2 * i + 1] << 8));
      ringPush(sample);
    }
  }
};

class ConfigCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    const std::string& v = c->getValue();
    if (v.size() < 3) return;
    const uint8_t* p = (const uint8_t*)v.data();
    uint16_t d = p[0] | (p[1] << 8);
    if (d > 2000) d = 2000;
    extraDelayMs = d;
    muted = p[2] != 0;
    Serial.printf("[cfg] extraDelay=%u ms mute=%d\n", d, muted);
  }
};

// ---------- I²S ----------
static void i2sSetup() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
  cfg.sample_rate = OUT_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 8;
  cfg.dma_buf_len = 64;
  cfg.use_apll = true;                    // cleaner clock for the DAC
  cfg.tx_desc_auto_clear = true;
#ifdef BOARD_A1S
  cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
#endif
  i2s_driver_install(I2S_NUM_0, &cfg, 0, nullptr);

  i2s_pin_config_t pins = {};
#ifdef BOARD_A1S
  pins.mck_io_num = PIN_MCLK;             // ES8388 needs MCLK (256 × fs)
#else
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
#endif
  pins.bck_io_num = PIN_BCK;
  pins.ws_io_num = PIN_LRCK;
  pins.data_out_num = PIN_DIN;
  pins.data_in_num = I2S_PIN_NO_CHANGE;
  i2s_set_pin(I2S_NUM_0, &pins);
  i2s_zero_dma_buffer(I2S_NUM_0);
}

// ---------- Output mute (DAC-specific) ----------
static volatile bool wantMute = true;     // set by audio task, applied by loop()/GPIO

#ifdef BOARD_A1S
// Minimal ES8388 bring-up: slave mode, I²S 16-bit, DAC → LOUT1/ROUT1 (headphone/line jack)
// and LOUT2/ROUT2 (speaker amp, which we leave powered off via PA_EN).
static bool esWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(ES8388_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static void codecInit() {
  pinMode(PIN_PA_EN, OUTPUT);
  digitalWrite(PIN_PA_EN, LOW);
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 100000);
  delay(10);
  bool ok = true;
  ok &= esWrite(0x19, 0x04);   // DACCONTROL3: DAC mute while configuring
  ok &= esWrite(0x01, 0x50);   // CONTROL2: power up analogue, VREF
  ok &= esWrite(0x02, 0x00);   // CHIPPOWER: everything on
  ok &= esWrite(0x08, 0x00);   // MASTERMODE: slave
  ok &= esWrite(0x04, 0xC0);   // DACPOWER: DAC off during setup
  ok &= esWrite(0x00, 0x12);   // CONTROL1: play mode
  ok &= esWrite(0x17, 0x18);   // DACCONTROL1: I²S, 16-bit
  ok &= esWrite(0x18, 0x02);   // DACCONTROL2: single speed, MCLK/LRCK = 256
  ok &= esWrite(0x26, 0x00);   // DACCONTROL16: mixer inputs (unused)
  ok &= esWrite(0x27, 0x90);   // DACCONTROL17: L DAC → L mixer, 0 dB
  ok &= esWrite(0x2A, 0x90);   // DACCONTROL20: R DAC → R mixer, 0 dB
  ok &= esWrite(0x2B, 0x80);   // DACCONTROL21: DAC/ADC share LRCK
  ok &= esWrite(0x2D, 0x00);   // DACCONTROL23: vroi = 0
  ok &= esWrite(0x1A, 0x00);   // DACCONTROL4: L DAC digital volume 0 dB
  ok &= esWrite(0x1B, 0x00);   // DACCONTROL5: R DAC digital volume 0 dB
  ok &= esWrite(0x2E, 0x1E);   // LOUT1 volume ≈ 0 dB
  ok &= esWrite(0x2F, 0x1E);   // ROUT1
  ok &= esWrite(0x30, 0x1E);   // LOUT2
  ok &= esWrite(0x31, 0x1E);   // ROUT2
  ok &= esWrite(0x04, 0x3C);   // DACPOWER: DAC on, LOUT1/ROUT1/LOUT2/ROUT2 on
  Serial.printf("[codec] ES8388 init %s\n", ok ? "ok" : "FAILED (check I2C / board variant)");
}

static void applyMute(bool m) {
  static int last = -1;
  if (last == (int)m) return;
  last = m;
  esWrite(0x19, m ? 0x04 : 0x00);   // DACCONTROL3 soft mute bit
}
#else
static void codecInit() {
  pinMode(PIN_XSMT, OUTPUT);
  digitalWrite(PIN_XSMT, LOW);
}
static void applyMute(bool m) { digitalWrite(PIN_XSMT, m ? LOW : HIGH); }
#endif

// ---------- Audio task ----------
// Pops one 1 kHz sample per iteration, emits 8 stereo frames at 8 kHz. i2s_write blocks on the
// DMA clock, so this loop is paced by the DAC and consumes exactly 1000 samples/s nominal.
static void audioTask(void*) {
  int16_t prev = 0;
  bool playing = false;
  uint32_t silentMs = 0;
  uint32_t iter = 0;
  int16_t frames[UPSAMPLE * 2];
  size_t written;

  for (;;) {
    uint32_t fill = ringFill();
    uint32_t target = targetFill();
    int16_t cur = 0;
    bool haveSample = false;

    if (!playing) {
      if (fill >= target) { playing = true; Serial.println("[audio] start"); }
    }

    if (playing) {
      if (fill == 0) {
        playing = false;
        statUnderruns++;
        Serial.println("[audio] underrun, rebuffering");
      } else {
        cur = ring[ringTail];
        ringTail = (ringTail + 1) & (RING_SIZE - 1);
        haveSample = true;
        // Drift control: once a second, nudge towards target by one sample.
        if ((++iter % 1000) == 0) {
          uint32_t f = ringFill();
          if (f > target + DRIFT_TOLERANCE) {
            ringTail = (ringTail + 1) & (RING_SIZE - 1);      // skip one (we're running slow)
          } else if (f + DRIFT_TOLERANCE < target && f > 0) {
            ringTail = (ringTail - 1) & (RING_SIZE - 1);      // repeat one (we're running fast)
          }
        }
      }
    }

    if (!haveSample) cur = 0;
    bool outputSilent = !haveSample || muted || !connected;
    if (outputSilent) {
      silentMs++;
      cur = 0;
    } else {
      silentMs = 0;
    }
    // Soft-mute the DAC after half a second of silence; un-mute as soon as audio flows.
    wantMute = (silentMs > 500 || muted);
#ifndef BOARD_A1S
    applyMute(wantMute);            // GPIO is cheap enough to do here
#endif

    // Linear interpolation prev → cur across 8 output frames, duplicated to L and R.
    for (int k = 0; k < UPSAMPLE; k++) {
      int32_t v = prev + ((int32_t)(cur - prev) * (k + 1)) / UPSAMPLE;
      frames[2 * k] = (int16_t)v;
      frames[2 * k + 1] = (int16_t)v;
    }
    prev = cur;
    i2s_write(I2S_NUM_0, frames, sizeof(frames), &written, portMAX_DELAY);
  }
}

// ---------- Setup / loop ----------
void setup() {
  Serial.begin(115200);
  codecInit();
  i2sSetup();

  NimBLEDevice::init("BassSub");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(247);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCB());

  NimBLEService* svc = server->createService(SVC_UUID);
  NimBLECharacteristic* audio = svc->createCharacteristic(AUDIO_UUID, NIMBLE_PROPERTY::WRITE_NR);
  audio->setCallbacks(new AudioCB());
  NimBLECharacteristic* config = svc->createCharacteristic(CONFIG_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::READ);
  config->setCallbacks(new ConfigCB());
  statusChar = svc->createCharacteristic(STATUS_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SVC_UUID);
  adv->setScanResponse(true);
  adv->setMinInterval(32);   // 20 ms
  adv->setMaxInterval(64);   // 40 ms
  adv->start();

  xTaskCreatePinnedToCore(audioTask, "audio", 4096, nullptr, configMAX_PRIORITIES - 2, nullptr, 1);
  Serial.println("[boot] BassSub advertising");
}

void loop() {
  static uint32_t lastStatus = 0;
  uint32_t now = millis();
#ifdef BOARD_A1S
  applyMute(wantMute);              // I²C write; done here, not on the audio task
#endif
  if (connected && statusChar && now - lastStatus >= 500) {
    lastStatus = now;
    uint16_t fill = (uint16_t)ringFill();
    uint8_t buf[6] = {
      (uint8_t)(fill & 0xFF), (uint8_t)(fill >> 8),
      (uint8_t)(statDroppedPkts & 0xFF), (uint8_t)(statDroppedPkts >> 8),
      (uint8_t)(statUnderruns & 0xFF), (uint8_t)(statUnderruns >> 8),
    };
    statusChar->setValue(buf, sizeof(buf));
    statusChar->notify();
  }
  delay(50);
}
