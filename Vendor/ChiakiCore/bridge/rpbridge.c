// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Bass Player: implementation of ChiakiBridge.h over chiaki-ng's lib (vendor/chiaki).
#include "ChiakiBridge.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <netdb.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>

// ---------------------------------------------------------------- Logging

static ChiakiLog g_log;
static rp_log_cb g_log_cb;
static void *g_log_user;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(g_log_cb)
		g_log_cb((int)level, msg, g_log_user);
}

int rp_init(rp_log_cb log_cb, void *log_user)
{
	g_log_cb = log_cb;
	g_log_user = log_user;
	chiaki_log_init(&g_log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, log_forward, NULL);
	ChiakiErrorCode err = chiaki_lib_init();
	if(err != CHIAKI_ERR_SUCCESS)
		CHIAKI_LOGE(&g_log, "chiaki_lib_init failed: %s", chiaki_error_string(err));
	return (int)err;
}

const char *rp_error_string(int err)
{
	return chiaki_error_string((ChiakiErrorCode)err);
}

// ---------------------------------------------------------------- Registration

struct rp_regist {
	ChiakiRegist regist;
	rp_regist_cb cb;
	void *user;
	pthread_mutex_t lock;
	bool fired;
};

static void regist_fire(rp_regist *r, int result, const rp_registered_host *host)
{
	pthread_mutex_lock(&r->lock);
	bool already = r->fired;
	r->fired = true;
	pthread_mutex_unlock(&r->lock);
	if(!already && r->cb)
		r->cb(result, host, r->user);
}

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	rp_regist *r = user;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			rp_registered_host host;
			memset(&host, 0, sizeof(host));
			ChiakiRegisteredHost *h = event->registered_host;
			if(h)
			{
				memcpy(host.nickname, h->server_nickname, sizeof(host.nickname));
				host.nickname[sizeof(host.nickname) - 1] = '\0';
				memcpy(host.mac, h->server_mac, sizeof(host.mac));
				memcpy(host.regist_key, h->rp_regist_key, sizeof(host.regist_key));
				memcpy(host.rp_key, h->rp_key, sizeof(host.rp_key));
				host.rp_key_type = h->rp_key_type;
				host.target = (int)h->target;
			}
			regist_fire(r, h ? 0 : 1, h ? &host : NULL);
			break;
		}
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			regist_fire(r, 2, NULL);
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
		default:
			regist_fire(r, 1, NULL);
			break;
	}
}

rp_regist *rp_regist_start(const char *host, bool ps5, const uint8_t account_id[RP_ACCOUNT_ID_SIZE],
                           uint32_t pin, rp_regist_cb cb, void *user)
{
	if(!host || !account_id)
		return NULL;
	rp_regist *r = calloc(1, sizeof(*r));
	if(!r)
		return NULL;
	pthread_mutex_init(&r->lock, NULL);
	r->cb = cb;
	r->user = user;

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.host = host;            // chiaki_regist_start copies it
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiErrorCode err = chiaki_regist_start(&r->regist, &g_log, &info, regist_cb, r);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "regist start failed: %s", chiaki_error_string(err));
		pthread_mutex_destroy(&r->lock);
		free(r);
		return NULL;
	}
	return r;
}

void rp_regist_free(rp_regist *r)
{
	if(!r)
		return;
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);   // joins the thread
	regist_fire(r, 2, NULL);
	pthread_mutex_destroy(&r->lock);
	free(r);
}

// ---------------------------------------------------------------- Wake-up and probe

int rp_wakeup(const char *host, bool ps5, const char regist_key[RP_REGIST_KEY_SIZE])
{
	char key[RP_REGIST_KEY_SIZE + 1];
	memcpy(key, regist_key, RP_REGIST_KEY_SIZE);
	key[RP_REGIST_KEY_SIZE] = '\0';
	// The credential is the regist key read as hex (8 characters, the rest is padding).
	key[strnlen(key, 8)] = '\0';
	char *end = NULL;
	uint64_t credential = strtoull(key, &end, 16);
	if(end == key)
	{
		CHIAKI_LOGE(&g_log, "wakeup: regist key is not hex");
		return (int)CHIAKI_ERR_INVALID_DATA;
	}
	return (int)chiaki_discovery_wakeup(&g_log, NULL, host, credential, ps5);
}

typedef struct probe_result {
	pthread_mutex_t lock;
	pthread_cond_t cond;
	bool done;
	int state;
	bool ps5;
	char name[128];
} probe_result;

static void probe_cb(ChiakiDiscoveryHost *host, void *user)
{
	probe_result *p = user;
	pthread_mutex_lock(&p->lock);
	if(!p->done)
	{
		p->done = true;
		p->state = host->state == CHIAKI_DISCOVERY_HOST_STATE_READY ? 1
			: host->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? 2 : 0;
		p->ps5 = chiaki_discovery_host_is_ps5(host);
		if(host->host_name)
			snprintf(p->name, sizeof(p->name), "%s", host->host_name);
		pthread_cond_broadcast(&p->cond);
	}
	pthread_mutex_unlock(&p->lock);
}

int rp_probe(const char *host, int timeout_ms, int *state, char *name_out, size_t name_size, bool *is_ps5)
{
	if(state) *state = 0;
	if(name_out && name_size) name_out[0] = '\0';

	struct addrinfo hints, *res = NULL;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	if(getaddrinfo(host, NULL, &hints, &res) != 0 || !res)
		return (int)CHIAKI_ERR_PARSE_ADDR;
	struct sockaddr_in addr;
	memcpy(&addr, res->ai_addr, sizeof(addr));
	freeaddrinfo(res);

	ChiakiDiscovery discovery;
	ChiakiErrorCode err = chiaki_discovery_init(&discovery, &g_log, AF_INET);
	if(err != CHIAKI_ERR_SUCCESS)
		return (int)err;

	probe_result p;
	memset(&p, 0, sizeof(p));
	pthread_mutex_init(&p.lock, NULL);
	pthread_cond_init(&p.cond, NULL);

	ChiakiDiscoveryThread thread;
	err = chiaki_discovery_thread_start_oneshot(&thread, &discovery, probe_cb, &p);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&discovery);
		pthread_cond_destroy(&p.cond);
		pthread_mutex_destroy(&p.lock);
		return (int)err;
	}

	// Ask on both the PS5 and the PS4 port; whichever console is there answers.
	ChiakiDiscoveryPacket packet;
	memset(&packet, 0, sizeof(packet));
	packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
	packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
	addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
	chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));
	packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;
	addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS4);
	chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));

	struct timeval now;
	gettimeofday(&now, NULL);
	struct timespec deadline;
	long long ns = (long long)now.tv_usec * 1000 + (long long)timeout_ms * 1000000LL;
	deadline.tv_sec = now.tv_sec + (time_t)(ns / 1000000000LL);
	deadline.tv_nsec = (long)(ns % 1000000000LL);
	pthread_mutex_lock(&p.lock);
	while(!p.done)
	{
		if(pthread_cond_timedwait(&p.cond, &p.lock, &deadline) != 0)
			break;
	}
	pthread_mutex_unlock(&p.lock);

	chiaki_discovery_thread_stop(&thread);   // joins; probe_cb can't run after this
	chiaki_discovery_fini(&discovery);

	if(p.done)
	{
		if(state) *state = p.state;
		if(is_ps5) *is_ps5 = p.ps5;
		if(name_out && name_size) snprintf(name_out, name_size, "%s", p.name);
	}
	pthread_cond_destroy(&p.cond);
	pthread_mutex_destroy(&p.lock);
	return p.done ? 0 : (int)CHIAKI_ERR_TIMEOUT;
}

// ---------------------------------------------------------------- Session

struct rp_session {
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	rp_callbacks cb;
	char host[256];
	ChiakiControllerState controller;
	pthread_mutex_t controller_lock;
	char quit_text[384];
	bool started;
};

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	rp_session *s = user;
	if(!s->cb.video)
		return true;
	return s->cb.video(buf, buf_size, frames_lost, frame_recovered, s->cb.user);
}

static void session_audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	rp_session *s = user;
	if(s->cb.audio_format)
		s->cb.audio_format(channels, rate, s->cb.user);
}

static void session_audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	rp_session *s = user;
	if(s->cb.audio)
		s->cb.audio(buf, samples_count, s->cb.user);
}

static void session_haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	rp_session *s = user;
	if(s->cb.haptics)
		s->cb.haptics((const int16_t *)buf, buf_size / (2 * sizeof(int16_t)), s->cb.user);
}

static void session_event_cb(ChiakiEvent *event, void *user)
{
	rp_session *s = user;
	if(!s->cb.event)
		return;
	rp_event e;
	memset(&e, 0, sizeof(e));
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			e.type = RP_EVENT_CONNECTED;
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			e.type = RP_EVENT_LOGIN_PIN_REQUEST;
			e.pin_incorrect = event->login_pin_request.pin_incorrect;
			break;
		case CHIAKI_EVENT_QUIT:
			e.type = RP_EVENT_QUIT;
			e.quit_reason = (int)event->quit.reason;
			e.quit_is_error = chiaki_quit_reason_is_error(event->quit.reason);
			snprintf(s->quit_text, sizeof(s->quit_text), "%s%s%s",
				chiaki_quit_reason_string(event->quit.reason),
				event->quit.reason_str ? ": " : "",
				event->quit.reason_str ? event->quit.reason_str : "");
			e.quit_text = s->quit_text;
			break;
		case CHIAKI_EVENT_RUMBLE:
			e.type = RP_EVENT_RUMBLE;
			e.rumble_left = event->rumble.left;
			e.rumble_right = event->rumble.right;
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			e.type = RP_EVENT_TRIGGER_EFFECTS;
			e.trigger_type_left = event->trigger_effects.type_left;
			e.trigger_type_right = event->trigger_effects.type_right;
			memcpy(e.trigger_left, event->trigger_effects.left, sizeof(e.trigger_left));
			memcpy(e.trigger_right, event->trigger_effects.right, sizeof(e.trigger_right));
			break;
		case CHIAKI_EVENT_LED_COLOR:
			e.type = RP_EVENT_LED;
			memcpy(e.led, event->led_state, sizeof(e.led));
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			e.type = RP_EVENT_NICKNAME;
			memcpy(e.nickname, event->server_nickname, sizeof(e.nickname));
			e.nickname[sizeof(e.nickname) - 1] = '\0';
			break;
		default:
			e.type = RP_EVENT_OTHER;
			break;
	}
	s->cb.event(&e, s->cb.user);
}

rp_session *rp_session_start(const rp_session_config *config, rp_callbacks callbacks, int *err_out)
{
	if(err_out) *err_out = 0;
	if(!config || !config->host)
	{
		if(err_out) *err_out = (int)CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	rp_session *s = calloc(1, sizeof(*s));
	if(!s)
	{
		if(err_out) *err_out = (int)CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->cb = callbacks;
	snprintf(s->host, sizeof(s->host), "%s", config->host);
	pthread_mutex_init(&s->controller_lock, NULL);
	chiaki_controller_state_set_idle(&s->controller);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = config->ps5;
	info.host = s->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->rp_key, sizeof(info.morning));
	ChiakiVideoResolutionPreset preset = CHIAKI_VIDEO_RESOLUTION_PRESET_1080p;
	if(config->height <= 360) preset = CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
	else if(config->height <= 540) preset = CHIAKI_VIDEO_RESOLUTION_PRESET_540p;
	else if(config->height <= 720) preset = CHIAKI_VIDEO_RESOLUTION_PRESET_720p;
	chiaki_connect_video_profile_preset(&info.video_profile, preset,
		config->max_fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
	if(config->bitrate_kbps > 0)
		info.video_profile.bitrate = config->bitrate_kbps;
	info.video_profile.codec = config->codec == RP_CODEC_H265_HDR ? CHIAKI_CODEC_H265_HDR
		: config->codec == RP_CODEC_H265 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = config->enable_dualsense;
	info.audio_video_disabled = CHIAKI_NONE_DISABLED;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	memcpy(info.psn_account_id, config->account_id, sizeof(info.psn_account_id));
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = config->idr_on_fec_failure;

	ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &g_log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "session init failed: %s", chiaki_error_string(err));
		pthread_mutex_destroy(&s->controller_lock);
		free(s);
		if(err_out) *err_out = (int)err;
		return NULL;
	}

	chiaki_opus_decoder_init(&s->opus, &g_log);
	chiaki_opus_decoder_set_cb(&s->opus, session_audio_settings_cb, session_audio_frame_cb, s);
	ChiakiAudioSink audio_sink;
	chiaki_opus_decoder_get_sink(&s->opus, &audio_sink);
	chiaki_session_set_audio_sink(&s->session, &audio_sink);

	if(callbacks.haptics)
	{
		ChiakiAudioSink haptics_sink;
		memset(&haptics_sink, 0, sizeof(haptics_sink));
		haptics_sink.user = s;
		haptics_sink.frame_cb = session_haptics_frame_cb;
		chiaki_session_set_haptics_sink(&s->session, &haptics_sink);
	}

	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);
	chiaki_session_set_event_cb(&s->session, session_event_cb, s);

	err = chiaki_session_start(&s->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "session start failed: %s", chiaki_error_string(err));
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
		pthread_mutex_destroy(&s->controller_lock);
		free(s);
		if(err_out) *err_out = (int)err;
		return NULL;
	}
	s->started = true;
	return s;
}

void rp_session_free(rp_session *s)
{
	if(!s)
		return;
	if(s->started)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
	}
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	pthread_mutex_destroy(&s->controller_lock);
	free(s);
}

void rp_session_set_controller(rp_session *s, const rp_controller_state *st)
{
	if(!s || !st)
		return;
	pthread_mutex_lock(&s->controller_lock);
	ChiakiControllerState *c = &s->controller;
	c->buttons = st->buttons;
	c->l2_state = st->l2;
	c->r2_state = st->r2;
	c->left_x = st->left_x;
	c->left_y = st->left_y;
	c->right_x = st->right_x;
	c->right_y = st->right_y;
	for(int i = 0; i < CHIAKI_CONTROLLER_TOUCHES_MAX; i++)
	{
		c->touches[i].x = st->touches[i].x;
		c->touches[i].y = st->touches[i].y;
		c->touches[i].id = st->touches[i].id;
	}
	c->gyro_x = st->gyro_x; c->gyro_y = st->gyro_y; c->gyro_z = st->gyro_z;
	c->accel_x = st->accel_x; c->accel_y = st->accel_y; c->accel_z = st->accel_z;
	c->orient_x = st->orient_x; c->orient_y = st->orient_y; c->orient_z = st->orient_z; c->orient_w = st->orient_w;
	ChiakiControllerState copy = *c;
	pthread_mutex_unlock(&s->controller_lock);
	chiaki_session_set_controller_state(&s->session, &copy);
}

void rp_session_set_login_pin(rp_session *s, const char *pin)
{
	if(!s || !pin)
		return;
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void rp_session_request_keyframe(rp_session *s)
{
	if(s)
		chiaki_session_request_idr(&s->session);
}

void rp_session_sleep_console(rp_session *s)
{
	if(s)
		chiaki_session_goto_bed(&s->session);
}
