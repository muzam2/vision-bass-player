// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Bass Player's C API over chiaki-ng's Remote Play core: the only header Swift sees.
// Everything here is local-network Remote Play (no PSN). All callbacks run on chiaki's own
// threads; the Swift side hops to its queues.
#ifndef CHIAKI_BRIDGE_H
#define CHIAKI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_ACCOUNT_ID_SIZE 8
#define RP_REGIST_KEY_SIZE 16
#define RP_KEY_SIZE 16

typedef void (*rp_log_cb)(int level, const char *msg, void *user);

/// Call once before anything else. 0 on success, otherwise a chiaki error code.
int rp_init(rp_log_cb log_cb, void *log_user);

/// Human-readable text for a chiaki error code.
const char *rp_error_string(int err);

// ---------------------------------------------------------------- Registration (pairing)

typedef struct rp_registered_host {
	char nickname[0x20];
	uint8_t mac[6];
	/// Pass both back to rp_session_start; `regist_key` also wakes the console.
	char regist_key[RP_REGIST_KEY_SIZE];
	uint8_t rp_key[RP_KEY_SIZE];
	uint32_t rp_key_type;
	int target;   // chiaki target (PS5 = 1000100)
} rp_registered_host;

/// result: 0 = success (host filled in), 1 = failed, 2 = cancelled.
typedef void (*rp_regist_cb)(int result, const rp_registered_host *host, void *user);

typedef struct rp_regist rp_regist;

/// Starts pairing with the console at `host` (IP or name) using the 8-digit PIN shown by
/// Settings > System > Remote Play > Link Device (or the get-pin payload) and the 8-byte
/// account ID of the user signed in on the console. NULL if it could not start.
rp_regist *rp_regist_start(const char *host, bool ps5, const uint8_t account_id[RP_ACCOUNT_ID_SIZE],
                           uint32_t pin, rp_regist_cb cb, void *user);
/// Stops (if still running) and frees. The callback fires (cancelled) before this returns if
/// it had not fired yet.
void rp_regist_free(rp_regist *regist);

// ---------------------------------------------------------------- Wake-up

/// Sends the wake-up packet to a console in rest mode. `regist_key` is the registered host's.
int rp_wakeup(const char *host, bool ps5, const char regist_key[RP_REGIST_KEY_SIZE]);

/// Asks the console at `host` for its state (unicast discovery). Blocks up to `timeout_ms`.
/// state: 0 unknown/no reply, 1 ready (on), 2 standby (rest mode). Name is filled if known.
int rp_probe(const char *host, int timeout_ms, int *state, char *name_out, size_t name_size, bool *is_ps5);

// ---------------------------------------------------------------- Streaming session

typedef enum {
	RP_EVENT_CONNECTED = 0,
	RP_EVENT_LOGIN_PIN_REQUEST = 1,   // console asks for the profile's login passcode
	RP_EVENT_QUIT = 2,
	RP_EVENT_RUMBLE = 3,
	RP_EVENT_TRIGGER_EFFECTS = 4,
	RP_EVENT_LED = 5,
	RP_EVENT_NICKNAME = 6,
	RP_EVENT_OTHER = 99
} rp_event_type;

typedef struct rp_event {
	rp_event_type type;
	int quit_reason;            // RP_EVENT_QUIT
	bool quit_is_error;
	const char *quit_text;      // reason string (static) plus remote detail, may be NULL
	bool pin_incorrect;         // RP_EVENT_LOGIN_PIN_REQUEST
	uint8_t rumble_left;        // RP_EVENT_RUMBLE: low-frequency motor 0-255
	uint8_t rumble_right;       //                  high-frequency motor 0-255
	uint8_t trigger_type_left;  // RP_EVENT_TRIGGER_EFFECTS (DualSense effect type + 10 bytes)
	uint8_t trigger_type_right;
	uint8_t trigger_left[10];
	uint8_t trigger_right[10];
	uint8_t led[3];             // RP_EVENT_LED
	char nickname[0x20];        // RP_EVENT_NICKNAME
} rp_event;

typedef struct rp_callbacks {
	void *user;
	/// One Annex-B access unit (or the codec header: SPS/PPS(/VPS) on its own, first).
	/// Return false if the frame could not be decoded; a keyframe is then requested.
	bool (*video)(const uint8_t *buf, size_t size, int32_t frames_lost, bool recovered, void *user);
	/// Audio format (before the first frame and whenever it changes).
	void (*audio_format)(uint32_t channels, uint32_t rate, void *user);
	/// Interleaved 16-bit PCM, `frames` samples per channel.
	void (*audio)(const int16_t *pcm, size_t frames, void *user);
	/// DualSense haptics as 16-bit PCM (3 kHz stereo on PS5), may be NULL.
	void (*haptics)(const int16_t *pcm, size_t frames, void *user);
	void (*event)(const rp_event *event, void *user);
} rp_callbacks;

typedef enum { RP_CODEC_H264 = 0, RP_CODEC_H265 = 1, RP_CODEC_H265_HDR = 2 } rp_codec;

typedef struct rp_session_config {
	const char *host;
	bool ps5;
	char regist_key[RP_REGIST_KEY_SIZE];
	uint8_t rp_key[RP_KEY_SIZE];
	uint8_t account_id[RP_ACCOUNT_ID_SIZE];
	unsigned int width, height, max_fps;
	unsigned int bitrate_kbps;     // 0 = chiaki's preset for the resolution
	rp_codec codec;
	bool enable_dualsense;         // haptics + adaptive trigger effects
	bool idr_on_fec_failure;
} rp_session_config;

typedef struct rp_session rp_session;

/// Connects and starts streaming. NULL plus *err on failure.
rp_session *rp_session_start(const rp_session_config *config, rp_callbacks callbacks, int *err);
/// Stops, waits for the threads and frees.
void rp_session_free(rp_session *session);

typedef struct rp_touch { uint16_t x, y; int8_t id; } rp_touch;   // 1920x1079 pad, id -1 = up

typedef struct rp_controller_state {
	uint32_t buttons;      // RP_BUTTON_* bitmask
	uint8_t l2, r2;        // 0-255
	int16_t left_x, left_y, right_x, right_y;  // y: negative = up
	rp_touch touches[2];
	float gyro_x, gyro_y, gyro_z;      // rad/s
	float accel_x, accel_y, accel_z;   // g
	float orient_x, orient_y, orient_z, orient_w;
} rp_controller_state;

enum {
	RP_BUTTON_CROSS = 1 << 0, RP_BUTTON_MOON = 1 << 1, RP_BUTTON_BOX = 1 << 2, RP_BUTTON_PYRAMID = 1 << 3,
	RP_BUTTON_DPAD_LEFT = 1 << 4, RP_BUTTON_DPAD_RIGHT = 1 << 5, RP_BUTTON_DPAD_UP = 1 << 6, RP_BUTTON_DPAD_DOWN = 1 << 7,
	RP_BUTTON_L1 = 1 << 8, RP_BUTTON_R1 = 1 << 9, RP_BUTTON_L3 = 1 << 10, RP_BUTTON_R3 = 1 << 11,
	RP_BUTTON_OPTIONS = 1 << 12, RP_BUTTON_SHARE = 1 << 13, RP_BUTTON_TOUCHPAD = 1 << 14, RP_BUTTON_PS = 1 << 15
};

void rp_session_set_controller(rp_session *session, const rp_controller_state *state);
void rp_session_set_login_pin(rp_session *session, const char *pin);
void rp_session_request_keyframe(rp_session *session);
/// Puts the console into rest mode.
void rp_session_sleep_console(rp_session *session);

#ifdef __cplusplus
}
#endif

#endif
