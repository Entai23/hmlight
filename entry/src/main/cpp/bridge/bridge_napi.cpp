// NAPI bridge between ArkTS and moonlight-common-c for HarmonyOS.
//
// M1 scope:
//   - load the portable moonlight-common-c core
//   - connection lifecycle + callback forwarding
//   - video/audio callbacks are accounted but not decoded yet (M2/M3)
//   - network diagnostics: TCP/TLS probe, LiTestClientConnectivity, RTT stats
//   - structured JSONL diagnostics written to the app sandbox for `hdc file recv`

#include <napi/native_api.h>

#include "diag.h"
#include "nvhttp.h"
#include "videodec.h"
#include "audiodec.h"
#include "Limelight.h"

extern "C" unsigned long long LiDiagGetUdpRxBytes(void);
extern "C" void LiDiagResetUdpRxBytes(void);

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/error.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/entropy.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <condition_variable>

#define LI_VERSION_STRING "moonlight-common-c/" MC_COMMIT

namespace {

// ---------------------------------------------------------------------------
// NAPI helpers
// ---------------------------------------------------------------------------
std::atomic<napi_threadsafe_function> g_tsfn{nullptr};

struct BridgeEvent {
    std::string type;
    std::string payload;
};

void CallJs(napi_env env, napi_value jsCb, void*, void* data) {
    BridgeEvent* ev = static_cast<BridgeEvent*>(data);
    if (ev == nullptr) {
        return;
    }
    if (env != nullptr && jsCb != nullptr) {
        napi_value argv[2];
        napi_create_string_utf8(env, ev->type.c_str(), NAPI_AUTO_LENGTH, &argv[0]);
        napi_create_string_utf8(env, ev->payload.c_str(), NAPI_AUTO_LENGTH, &argv[1]);
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_call_function(env, undef, jsCb, 2, argv, nullptr);
    }
    delete ev;
}

void Emit(const std::string& type, const std::string& payload) {
    mdiag::EventJson("event", "\"type\":\"" + mdiag::JsonEscape(type) + "\",\"payload\":" + payload);
    napi_threadsafe_function fn = g_tsfn.load(std::memory_order_acquire);
    if (fn == nullptr) {
        return;
    }
    BridgeEvent* ev = new BridgeEvent{type, payload};
    if (napi_call_threadsafe_function(fn, ev, napi_tsfn_nonblocking) != napi_ok) {
        delete ev;
    }
}

static void ReleaseTsfn() {
    napi_threadsafe_function old = g_tsfn.exchange(nullptr, std::memory_order_acq_rel);
    if (old != nullptr) {
        napi_release_threadsafe_function(old, napi_tsfn_release);
    }
}

napi_value MakeString(napi_env env, const std::string& s) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

napi_value MakeInt(napi_env env, int32_t v) {
    napi_value out = nullptr;
    napi_create_int32(env, v, &out);
    return out;
}

std::string GetString(napi_env env, napi_value value) {
    if (value == nullptr) {
        return std::string();
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type != napi_string) {
        return std::string();
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string out(len + 1, '\0');
    napi_get_value_string_utf8(env, value, &out[0], len + 1, &len);
    out.resize(len);
    return out;
}

int32_t GetInt(napi_env env, napi_value value, int32_t def) {
    if (value == nullptr) {
        return def;
    }
    int32_t out = def;
    if (napi_get_value_int32(env, value, &out) != napi_ok) {
        return def;
    }
    return out;
}

bool GetBool(napi_env env, napi_value value, bool def) {
    if (value == nullptr) {
        return def;
    }
    bool out = def;
    if (napi_get_value_bool(env, value, &out) != napi_ok) {
        return def;
    }
    return out;
}

std::string IsoNowMs() {
    return std::to_string(mdiag::NowUs() / 1000);
}

// ---------------------------------------------------------------------------
// Bridge state
// ---------------------------------------------------------------------------
std::atomic<bool> g_connected{false};
std::mutex g_connMutex;
std::atomic<bool> g_statsRunning{false};
std::atomic<uint64_t> g_videoFrames{0};
std::atomic<uint64_t> g_videoBytes{0};
std::atomic<uint64_t> g_audioPackets{0};
std::atomic<uint64_t> g_connectStartUs{0};
std::atomic<uint64_t> g_lastFrameUs{0};
std::atomic<uint32_t> g_lastHostLatencyTenthsMs{0};
std::mutex g_stateMutex;
std::string g_httpDataDir;
std::string g_videoFormatName = "unknown";
int g_videoWidth = 0;
int g_videoHeight = 0;
int g_videoFps = 0;
int g_decodeUnitErrors = 0;
std::thread g_statsThread;
std::mutex g_statsMutex;
std::mutex g_statsThreadMutex;
std::condition_variable g_statsCv;

void StopStatsThread() {
    std::lock_guard<std::mutex> lock(g_statsThreadMutex);
    g_statsRunning.store(false);
    g_statsCv.notify_all();
    if (g_statsThread.joinable()) {
        g_statsThread.join();
    }
}

const char* VideoFormatName(int format) {
    switch (format) {
        case VIDEO_FORMAT_H264: return "H.264";
        case VIDEO_FORMAT_H265: return "HEVC";
        case VIDEO_FORMAT_H265_MAIN10: return "HEVC Main10";
        case VIDEO_FORMAT_AV1_MAIN8: return "AV1";
        case VIDEO_FORMAT_AV1_MAIN10: return "AV1 Main10";
        default: return "unknown";
    }
}

// ---------------------------------------------------------------------------
// Core callbacks
// ---------------------------------------------------------------------------
int BridgeDrSetup(int videoFormat, int width, int height, int redrawRate, void*, int drFlags) {
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_videoFormatName = VideoFormatName(videoFormat);
        g_videoWidth = width;
        g_videoHeight = height;
        g_videoFps = redrawRate;
    }
    mdiag::Log("video", "decoder setup format=%s (%d) %dx%d@%d flags=0x%x",
               VideoFormatName(videoFormat), videoFormat, width, height, redrawRate, drFlags);
    videodec::Setup(videoFormat, width, height, redrawRate);
    Emit("videoSetup", "{\"format\":\"" + std::string(VideoFormatName(videoFormat)) +
                       "\",\"width\":" + std::to_string(width) +
                       ",\"height\":" + std::to_string(height) +
                       ",\"fps\":" + std::to_string(redrawRate) +
                       ",\"flags\":" + std::to_string(drFlags) + "}");
    return 0;
}

void BridgeDrStart(void) {
    videodec::Start();
    LiRequestIdrFrame();
    mdiag::Log("video", "decoder start");
    Emit("videoStart", "{}");
}

void BridgeDrStop(void) {
    videodec::Stop();
    mdiag::Log("video", "decoder stop");
    Emit("videoStop", "{}");
}

void BridgeDrCleanup(void) {
    videodec::Cleanup();
    mdiag::Log("video", "decoder cleanup");
}

int BridgeDrSubmitDecodeUnit(PDECODE_UNIT du) {
    g_videoFrames.fetch_add(1);
    g_videoBytes.fetch_add(static_cast<uint64_t>(du->fullLength));
    g_lastFrameUs.store(mdiag::NowUs());
    g_lastHostLatencyTenthsMs.store(du->frameHostProcessingLatency);

    uint64_t n = g_videoFrames.load();
    if (n % 120 == 0) {
        uint64_t now = mdiag::NowUs();
        uint64_t enqueueDelay = now > du->enqueueTimeUs ? now - du->enqueueTimeUs : 0;
        mdiag::Log("video", "frame=%llu type=%d len=%d hostLatency=%.1fms queueDelay=%.2fms",
                   static_cast<unsigned long long>(n), du->frameType, du->fullLength,
                   du->frameHostProcessingLatency / 10.0, enqueueDelay / 1000.0);
    }
    if (!videodec::Submit(du)) {
        static std::atomic<uint64_t> lastIdrReqUs{0};
        uint64_t nowUs = mdiag::NowUs();
        uint64_t lastUs = lastIdrReqUs.load();
        if (nowUs - lastUs > 500000) {
            if (lastIdrReqUs.compare_exchange_strong(lastUs, nowUs)) {
                LiRequestIdrFrame();
                mdiag::Log("vdec", "requested IDR after frame loss");
            }
        }
        return DR_NEED_IDR;
    }
    return DR_OK;
}

int BridgeArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void*, int flags) {
    mdiag::Log("audio", "init cfg=%d channels=%d rate=%d frame=%d streams=%d coupled=%d flags=0x%x",
               audioConfiguration, opusConfig ? opusConfig->channelCount : 0,
               opusConfig ? opusConfig->sampleRate : 0, opusConfig ? opusConfig->samplesPerFrame : 0,
               opusConfig ? opusConfig->streams : 0, opusConfig ? opusConfig->coupledStreams : 0, flags);
    Emit("audioInit", "{\"channels\":" + std::to_string(opusConfig ? opusConfig->channelCount : 0) +
                      ",\"sampleRate\":" + std::to_string(opusConfig ? opusConfig->sampleRate : 0) +
                      ",\"samplesPerFrame\":" + std::to_string(opusConfig ? opusConfig->samplesPerFrame : 0) + "}");
    if (!audiodec::Init(audioConfiguration, opusConfig, flags)) {
        mdiag::Log("audio", "audio init failed, stream continues without audio");
    }
    return 0;
}

void BridgeArStart(void) {
    audiodec::Start();
    mdiag::Log("audio", "start");
}

void BridgeArStop(void) {
    audiodec::Stop();
    mdiag::Log("audio", "stop");
}

void BridgeArCleanup(void) {
    audiodec::Cleanup();
    mdiag::Log("audio", "cleanup");
}

void BridgeArDecodeAndPlaySample(char* sampleData, int sampleLength) {
    g_audioPackets.fetch_add(1);
    audiodec::DecodeAndPlaySample(sampleData, sampleLength);
    if (g_audioPackets.load() % 500 == 0) {
        mdiag::Log("audio", "opus packets=%llu lastLen=%d",
                   static_cast<unsigned long long>(g_audioPackets.load()), sampleLength);
    }
}

void BridgeClStageStarting(int stage) {
    uint64_t elapsed = 0;
    uint64_t start = g_connectStartUs.load();
    if (start != 0) {
        elapsed = (mdiag::NowUs() - start) / 1000;
    }
    const char* name = LiGetStageName(stage);
    mdiag::Log("conn", "stage start %d (%s) +%llums", stage, name ? name : "?", static_cast<unsigned long long>(elapsed));
    Emit("stage", "{\"stage\":" + std::to_string(stage) + ",\"name\":\"" +
                  mdiag::JsonEscape(name ? name : "") + "\",\"elapsedMs\":" + std::to_string(elapsed) + "}");
}

void BridgeClStageComplete(int stage) {
    uint64_t start = g_connectStartUs.load();
    uint64_t elapsed = start ? (mdiag::NowUs() - start) / 1000 : 0;
    mdiag::Log("conn", "stage complete %d +%llums", stage, static_cast<unsigned long long>(elapsed));
    Emit("stageComplete", "{\"stage\":" + std::to_string(stage) + ",\"elapsedMs\":" + std::to_string(elapsed) + "}");
}

void BridgeClStageFailed(int stage, int errorCode) {
    mdiag::Log("conn", "stage failed %d errorCode=%d (%s)", stage, errorCode, LiGetStageName(stage));
    Emit("stageFailed", "{\"stage\":" + std::to_string(stage) + ",\"errorCode\":" + std::to_string(errorCode) + "}");
}

void BridgeClConnectionStarted(void) {
    g_connected.store(true);
    uint64_t start = g_connectStartUs.load();
    uint64_t elapsed = start ? (mdiag::NowUs() - start) / 1000 : 0;
    mdiag::Log("conn", "connection started +%llums", static_cast<unsigned long long>(elapsed));
    Emit("connected", "{\"elapsedMs\":" + std::to_string(elapsed) + "}");

    {
        std::lock_guard<std::mutex> lock(g_statsThreadMutex);
        if (!g_statsRunning.exchange(true)) {
            // Ensure any previous stats thread has fully exited before replacing it.
            if (g_statsThread.joinable()) {
                g_statsRunning.store(false);
                g_statsCv.notify_all();
                g_statsThread.join();
                g_statsRunning.store(true);
            }
            g_statsThread = std::thread([]() {
            uint64_t lastFrames = g_videoFrames.load();
            uint64_t lastUs = mdiag::NowUs();
            while (true) {
                {
                    std::unique_lock<std::mutex> lock(g_statsMutex);
                    g_statsCv.wait_for(lock, std::chrono::milliseconds(2000), []() {
                        return !g_statsRunning.load();
                    });
                    if (!g_statsRunning.load()) {
                        break;
                    }
                }
                uint64_t now = mdiag::NowUs();
                uint64_t frames = g_videoFrames.load();
                double secs = (now - lastUs) / 1000000.0;
                double fps = secs > 0 ? static_cast<double>(frames - lastFrames) / secs : 0;
                lastFrames = frames;
                lastUs = now;

                uint32_t rtt = 0;
                uint32_t variance = 0;
                bool haveRtt = LiGetEstimatedRttInfo(&rtt, &variance);
                char buf[512];
                snprintf(buf, sizeof(buf),
                         "{\"fps\":%.2f,\"frames\":%llu,\"bytes\":%llu,\"audioPackets\":%llu,"
                         "\"rttUs\":%u,\"rttVarianceUs\":%u,\"pendingVideoFrames\":%d,\"pendingAudioMs\":%d}",
                         fps, static_cast<unsigned long long>(frames),
                         static_cast<unsigned long long>(g_videoBytes.load()),
                         static_cast<unsigned long long>(g_audioPackets.load()),
                         haveRtt ? rtt : 0, haveRtt ? variance : 0,
                         LiGetPendingVideoFrames(), LiGetPendingAudioDuration());
                mdiag::Log("stats", "%s", buf);
                Emit("stats", buf);
            }
            });
        }
    }
}

void BridgeClConnectionTerminated(int errorCode) {
    g_connected.store(false);
    StopStatsThread();
    mdiag::Log("conn", "connection terminated errorCode=%d", errorCode);
    Emit("terminated", "{\"errorCode\":" + std::to_string(errorCode) + "}");
}

void BridgeClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor) {
    Emit("rumble", "{\"controller\":" + std::to_string(controllerNumber) +
                   ",\"lowFreq\":" + std::to_string(lowFreqMotor) +
                   ",\"highFreq\":" + std::to_string(highFreqMotor) + "}");
}

void BridgeClConnectionStatusUpdate(int status) {
    mdiag::Log("conn", "status=%d", status);
    Emit("status", "{\"connectionStatus\":" + std::to_string(status) + "}");
}

void BridgeClSetHdrMode(bool enabled) {
    mdiag::Log("display", "hdr mode=%d", enabled ? 1 : 0);
    Emit("hdr", std::string("{\"enabled\":") + (enabled ? "true" : "false") + "}");
}

void BridgeClRumbleTriggers(unsigned short controllerNumber, unsigned short leftTrigger, unsigned short rightTrigger) {
    Emit("rumbleTriggers", "{\"controller\":" + std::to_string(controllerNumber) +
                           ",\"left\":" + std::to_string(leftTrigger) +
                           ",\"right\":" + std::to_string(rightTrigger) + "}");
}

void BridgeClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz) {
    Emit("motionState", "{\"controller\":" + std::to_string(controllerNumber) +
                        ",\"motionType\":" + std::to_string(motionType) +
                        ",\"reportRateHz\":" + std::to_string(reportRateHz) + "}");
}

void BridgeClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b) {
    Emit("led", "{\"controller\":" + std::to_string(controllerNumber) +
                ",\"r\":" + std::to_string(r) + ",\"g\":" + std::to_string(g) +
                ",\"b\":" + std::to_string(b) + "}");
}

void BridgeClLogMessage(const char* format, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, format);
    vsnprintf(msg, sizeof(msg), format, ap);
    va_end(ap);
    size_t len = strlen(msg);
    while (len > 0 && (msg[len - 1] == '\n' || msg[len - 1] == '\r')) {
        msg[--len] = '\0';
    }
    mdiag::Log("core", "%s", msg);
}

DECODER_RENDERER_CALLBACKS g_drCallbacks;
AUDIO_RENDERER_CALLBACKS g_arCallbacks;
CONNECTION_LISTENER_CALLBACKS g_clCallbacks;

void InitCallbacks() {
    memset(&g_drCallbacks, 0, sizeof(g_drCallbacks));
    g_drCallbacks.setup = BridgeDrSetup;
    g_drCallbacks.start = BridgeDrStart;
    g_drCallbacks.stop = BridgeDrStop;
    g_drCallbacks.cleanup = BridgeDrCleanup;
    g_drCallbacks.submitDecodeUnit = BridgeDrSubmitDecodeUnit;
    g_drCallbacks.capabilities = 0;

    memset(&g_arCallbacks, 0, sizeof(g_arCallbacks));
    g_arCallbacks.init = BridgeArInit;
    g_arCallbacks.start = BridgeArStart;
    g_arCallbacks.stop = BridgeArStop;
    g_arCallbacks.cleanup = BridgeArCleanup;
    g_arCallbacks.decodeAndPlaySample = BridgeArDecodeAndPlaySample;
    g_arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    memset(&g_clCallbacks, 0, sizeof(g_clCallbacks));
    g_clCallbacks.stageStarting = BridgeClStageStarting;
    g_clCallbacks.stageComplete = BridgeClStageComplete;
    g_clCallbacks.stageFailed = BridgeClStageFailed;
    g_clCallbacks.connectionStarted = BridgeClConnectionStarted;
    g_clCallbacks.connectionTerminated = BridgeClConnectionTerminated;
    g_clCallbacks.logMessage = BridgeClLogMessage;
    g_clCallbacks.rumble = BridgeClRumble;
    g_clCallbacks.connectionStatusUpdate = BridgeClConnectionStatusUpdate;
    g_clCallbacks.setHdrMode = BridgeClSetHdrMode;
    g_clCallbacks.rumbleTriggers = BridgeClRumbleTriggers;
    g_clCallbacks.setMotionEventState = BridgeClSetMotionEventState;
    g_clCallbacks.setControllerLED = BridgeClSetControllerLED;
}

// ---------------------------------------------------------------------------
// Network diagnostics
// ---------------------------------------------------------------------------
int64_t TcpConnectMs(const std::string& host, int port, int timeoutMs) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), portStr, &hints, &res) != 0 || res == nullptr) {
        return -1;
    }

    int64_t elapsed = -1;
    for (struct addrinfo* ai = res; ai != nullptr; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_NONBLOCK, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        uint64_t begin = mdiag::NowUs();
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc < 0 && errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            rc = poll(&pfd, 1, timeoutMs);
            if (rc > 0) {
                int soError = 0;
                socklen_t len = sizeof(soError);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len);
                rc = soError == 0 ? 0 : -1;
            } else {
                rc = -1;
            }
        }
        if (rc == 0) {
            elapsed = static_cast<int64_t>((mdiag::NowUs() - begin) / 1000);
            close(fd);
            break;
        }
        close(fd);
    }
    freeaddrinfo(res);
    return elapsed;
}


void LogMbedtlsError(const char* stage, int rc) {
    char err[200] = {0};
    mbedtls_strerror(rc, err, sizeof(err));
    mdiag::Log("net", "%s failed rc=-0x%04x (%s)", stage, -rc, err);
}

std::string HttpGetServerInfo(const std::string& host, int port, int timeoutMs, int* httpOk,
                              std::string* errOut) {
    *httpOk = 0;
    mbedtls_net_context server;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctrDrbg;

    mbedtls_net_init(&server);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctrDrbg);

    std::string body;

    do {
        const char* pers = "moonlight-ohos-probe";
        int rc = mbedtls_ctr_drbg_seed(&ctrDrbg, mbedtls_entropy_func, &entropy,
                                       reinterpret_cast<const unsigned char*>(pers), strlen(pers));
        if (rc != 0) {
            LogMbedtlsError("ctr_drbg_seed", rc);
            *errOut = "ctr_drbg_seed";
            break;
        }
        rc = mbedtls_net_connect(&server, host.c_str(), std::to_string(port).c_str(),
                                 MBEDTLS_NET_PROTO_TCP);
        if (rc != 0) {
            LogMbedtlsError("net_connect", rc);
            *errOut = "net_connect";
            break;
        }
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        setsockopt(server.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(server.fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        rc = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                         MBEDTLS_SSL_PRESET_DEFAULT);
        if (rc != 0) {
            LogMbedtlsError("ssl_config_defaults", rc);
            *errOut = "ssl_config_defaults";
            break;
        }
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctrDrbg);
        if (nvhttp::EnsureClientCert(nullptr)) {
            mbedtls_ssl_conf_own_cert(&conf, nvhttp::ClientCrt(), nvhttp::ClientKey());
        }
        rc = mbedtls_ssl_setup(&ssl, &conf);
        if (rc != 0) {
            LogMbedtlsError("ssl_setup", rc);
            *errOut = "ssl_setup";
            break;
        }
        mbedtls_ssl_set_hostname(&ssl, host.c_str());
        mbedtls_ssl_set_bio(&ssl, &server, mbedtls_net_send, mbedtls_net_recv, nullptr);

        rc = mbedtls_ssl_handshake(&ssl);
        if (rc != 0) {
            LogMbedtlsError("ssl_handshake", rc);
            *errOut = "ssl_handshake";
            break;
        }

        char req[512];
        snprintf(req, sizeof(req),
                 "GET /serverinfo?uniqueid=0123456789ABCDEF&uuid=0123456789ABCDEF0123456789ABCDEF HTTP/1.0\r\n"
                 "Host: %s:%d\r\n"
                 "Connection: close\r\n\r\n",
                 host.c_str(), port);
        rc = mbedtls_ssl_write(&ssl, reinterpret_cast<const unsigned char*>(req), strlen(req));
        if (rc <= 0) {
            LogMbedtlsError("ssl_write", rc);
            *errOut = "ssl_write";
            break;
        }

        char buf[1024];
        std::string raw;
        while (raw.size() < 8192) {
            int n = mbedtls_ssl_read(&ssl, reinterpret_cast<unsigned char*>(buf), sizeof(buf) - 1);
            if (n <= 0) {
                if (raw.empty()) {
                    LogMbedtlsError("ssl_read", n);
                    *errOut = "ssl_read";
                }
                break;
            }
            buf[n] = '\0';
            raw.append(buf, static_cast<size_t>(n));
            if (raw.find("</root>") != std::string::npos) {
                break;
            }
        }
        size_t headerEnd = raw.find("\r\n\r\n");
        if (raw.rfind("HTTP/1.", 0) == 0) {
            size_t lineEnd = raw.find("\r\n");
            std::string statusLine = raw.substr(0, lineEnd);
            if (statusLine.find("200") != std::string::npos) {
                *httpOk = 1;
            }
            mdiag::Log("net", "https status: %s", statusLine.c_str());
        }
        if (headerEnd != std::string::npos) {
            body = raw.substr(headerEnd + 4);
        } else {
            body = raw;
        }
        if (body.size() > 1500) {
            body.resize(1500);
        }
    } while (false);

    mbedtls_ssl_close_notify(&ssl);
    mbedtls_net_free(&server);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_ctr_drbg_free(&ctrDrbg);
    mbedtls_entropy_free(&entropy);
    return body;
}

std::string HttpGetPlain(const std::string& host, int port, int timeoutMs, int* httpOk,
                          std::string* errOut) {
    *httpOk = 0;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), portStr, &hints, &res) != 0 || res == nullptr) {
        *errOut = "getaddrinfo";
        return std::string();
    }

    int fd = -1;
    for (struct addrinfo* ai = res; ai != nullptr; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        *errOut = "connect";
        return std::string();
    }

    char req[512];
    snprintf(req, sizeof(req),
             "GET /serverinfo?uniqueid=0123456789ABCDEF&uuid=0123456789ABCDEF0123456789ABCDEF HTTP/1.0\r\n"
             "Host: %s:%d\r\n"
             "Connection: close\r\n\r\n",
             host.c_str(), port);
    if (send(fd, req, strlen(req), 0) <= 0) {
        *errOut = "send";
        close(fd);
        return std::string();
    }

    std::string raw;
    char buf[1024];
    while (raw.size() < 8192) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) {
            break;
        }
        raw.append(buf, static_cast<size_t>(n));
        if (raw.find("</root>") != std::string::npos) {
            break;
        }
    }
    close(fd);

    size_t headerEnd = raw.find("\r\n\r\n");
    if (raw.rfind("HTTP/1.", 0) == 0) {
        size_t lineEnd = raw.find("\r\n");
        std::string statusLine = raw.substr(0, lineEnd);
        if (statusLine.find("200") != std::string::npos) {
            *httpOk = 1;
        }
        mdiag::Log("net", "http status: %s", statusLine.c_str());
    } else if (raw.empty()) {
        *errOut = "empty_response";
    }
    std::string body = headerEnd != std::string::npos ? raw.substr(headerEnd + 4) : raw;
    if (body.size() > 1500) {
        body.resize(1500);
    }
    return body;
}

struct AsyncData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_env env = nullptr;
    std::string host;
    int timeoutMs = 3000;
    std::string resultJson;
    int resultInt = 0;
};

void ProbeExecute(napi_env, void* data) {
    AsyncData* d = static_cast<AsyncData*>(data);

    int64_t tcp84 = TcpConnectMs(d->host, 47984, d->timeoutMs);
    int64_t tcp89 = TcpConnectMs(d->host, 47989, d->timeoutMs);
    int64_t tcp10 = TcpConnectMs(d->host, 48010, d->timeoutMs);

    int httpOk = 0;
    std::string serverInfo;
    std::string tlsError;
    int64_t tlsMs = -1;
    if (tcp84 >= 0) {
        uint64_t begin = mdiag::NowUs();
        serverInfo = HttpGetServerInfo(d->host, 47984, d->timeoutMs, &httpOk, &tlsError);
        if (!serverInfo.empty() || httpOk) {
            tlsMs = static_cast<int64_t>((mdiag::NowUs() - begin) / 1000);
        }
    }

    int httpPlainOk = 0;
    std::string httpPlainError;
    std::string httpPlainInfo;
    if (tcp89 >= 0) {
        httpPlainInfo = HttpGetPlain(d->host, 47989, d->timeoutMs, &httpPlainOk, &httpPlainError);
    }

    char buf[8192];
    snprintf(buf, sizeof(buf),
             "{\"host\":\"%s\",\"tcp47984Ms\":%lld,\"tcp47989Ms\":%lld,\"tcp48010Ms\":%lld,"
             "\"tlsMs\":%lld,\"httpOk\":%s,\"tlsError\":\"%s\",\"serverinfo\":\"%s\","
             "\"httpPlainOk\":%s,\"httpPlainError\":\"%s\",\"httpPlainInfo\":\"%s\"}",
             mdiag::JsonEscape(d->host).c_str(),
             static_cast<long long>(tcp84), static_cast<long long>(tcp89),
             static_cast<long long>(tcp10), static_cast<long long>(tlsMs),
             httpOk ? "true" : "false", mdiag::JsonEscape(tlsError).c_str(),
             mdiag::JsonEscape(serverInfo).c_str(),
             httpPlainOk ? "true" : "false", mdiag::JsonEscape(httpPlainError).c_str(),
             mdiag::JsonEscape(httpPlainInfo).c_str());
    d->resultJson = buf;
    mdiag::Log("net", "probe %s", d->resultJson.c_str());
}

void ConnectivityExecute(napi_env, void* data) {
    AsyncData* d = static_cast<AsyncData*>(data);
    uint64_t begin = mdiag::NowUs();
    d->resultInt = static_cast<int>(LiTestClientConnectivity(d->host.c_str(), 47989, ML_PORT_FLAG_ALL));
    mdiag::Log("net", "connectivity test %s result=0x%x (%lld ms)", d->host.c_str(), d->resultInt,
               static_cast<long long>((mdiag::NowUs() - begin) / 1000));
}

void GenericComplete(napi_env env, napi_status status, void* data) {
    AsyncData* d = static_cast<AsyncData*>(data);
    if (d->deferred != nullptr) {
        napi_value value;
        if (d->resultJson.empty()) {
            napi_create_int32(env, d->resultInt, &value);
        } else {
            napi_create_string_utf8(env, d->resultJson.c_str(), NAPI_AUTO_LENGTH, &value);
        }
        napi_resolve_deferred(env, d->deferred, value);
    }
    napi_delete_async_work(env, d->work);
    delete d;
}

// ---------------------------------------------------------------------------
// startConnection async work
// ---------------------------------------------------------------------------
struct StartData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_env env = nullptr;
    std::string address;
    std::string appVersion;
    std::string gfeVersion;
    std::string rtspSessionUrl;
    bool hasGfe = false;
    bool hasRtsp = false;
    int serverCodecModeSupport = 0;
    int width = 1920;
    int height = 1080;
    int fps = 60;
    int bitrate = 20000;
    int packetSize = 1024;
    int streamingRemotely = STREAM_CFG_AUTO;
    int audioConfiguration = 0;
    int supportedVideoFormats = VIDEO_FORMAT_H264;
    int clientRefreshRateX100 = 0;
    int videoCapabilities = 0;
    int colorSpace = 0;
    int colorRange = 0;
    unsigned char riKey[16] = {0};
    unsigned char riIv[16] = {0};
    int result = -1;
};

void StartExecute(napi_env, void* data) {
    StartData* d = static_cast<StartData*>(data);

    SERVER_INFORMATION serverInfo;
    memset(&serverInfo, 0, sizeof(serverInfo));
    serverInfo.address = d->address.c_str();
    serverInfo.serverInfoAppVersion = d->appVersion.c_str();
    serverInfo.serverInfoGfeVersion = d->hasGfe ? d->gfeVersion.c_str() : nullptr;
    serverInfo.rtspSessionUrl = d->hasRtsp ? d->rtspSessionUrl.c_str() : nullptr;
    serverInfo.serverCodecModeSupport = d->serverCodecModeSupport;

    STREAM_CONFIGURATION streamConfig;
    memset(&streamConfig, 0, sizeof(streamConfig));
    streamConfig.width = d->width;
    streamConfig.height = d->height;
    streamConfig.fps = d->fps;
    streamConfig.bitrate = d->bitrate;
    mdiag::Log("conn", "stream config %dx%d@%d bitrate=%d kbps (SDP will use 80%%=%d)",
               d->width, d->height, d->fps, d->bitrate, (int)(d->bitrate * 0.8));
    streamConfig.packetSize = d->packetSize;
    streamConfig.streamingRemotely = d->streamingRemotely;
    streamConfig.audioConfiguration = d->audioConfiguration;
    streamConfig.supportedVideoFormats = d->supportedVideoFormats;
    streamConfig.clientRefreshRateX100 = d->clientRefreshRateX100;
    streamConfig.colorSpace = d->colorSpace;
    streamConfig.colorRange = d->colorRange;
    streamConfig.encryptionFlags = ENCFLG_ALL;
    memcpy(streamConfig.remoteInputAesKey, d->riKey, sizeof(d->riKey));
    memcpy(streamConfig.remoteInputAesIv, d->riIv, sizeof(d->riIv));

    g_connectStartUs.store(mdiag::NowUs());
    {
        std::lock_guard<std::mutex> lock(g_connMutex);
        LiDiagResetUdpRxBytes();
        // Recover from a stale session (e.g. the app was suspended and the
        // network threads never reported termination).
        if (g_connected.load()) {
            mdiag::Log("conn", "stale connection detected, resetting before start");
            LiInterruptConnection();
            LiStopConnection();
            g_connected.store(false);
        }
        d->result = LiStartConnection(&serverInfo, &streamConfig, &g_clCallbacks,
                                      &g_drCallbacks, &g_arCallbacks,
                                      nullptr, 0, nullptr, 0);
    }
    mdiag::Log("conn", "LiStartConnection returned %d", d->result);
}

// ---------------------------------------------------------------------------
// NAPI exports
// ---------------------------------------------------------------------------
napi_value JsInit(napi_env env, napi_callback_info) {
    InitCallbacks();
    mdiag::Log("app", "bridge init %s", LI_VERSION_STRING);
    return MakeInt(env, 0);
}

napi_value JsSetEventCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    ReleaseTsfn();
    if (argc < 1) {
        return MakeInt(env, 0);
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) {
        return MakeInt(env, 0);
    }
    napi_value name;
    napi_create_string_utf8(env, "moonbridgeEvents", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function fn = nullptr;
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1,
                                                          nullptr, nullptr, nullptr, CallJs, &fn);
    if (status == napi_ok && fn != nullptr) {
        g_tsfn.store(fn, std::memory_order_release);
    }
    return MakeInt(env, 0);
}

napi_value JsClearEventCallback(napi_env env, napi_callback_info) {
    ReleaseTsfn();
    return MakeInt(env, 0);
}

napi_value JsSetLogDir(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string dir = GetString(env, argc > 0 ? args[0] : nullptr);
    if (!dir.empty()) {
        g_httpDataDir = dir;
        nvhttp::SetDataDir(dir);
        mdiag::SetLogDir(dir);
    }
    return MakeString(env, mdiag::LogFilePath());
}

napi_value JsSetSurfaceId(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id = GetString(env, argc > 0 ? args[0] : nullptr);
    videodec::SetSurfaceId(id);
    return MakeInt(env, 0);
}

std::string PauseMarkerPath() {
    return g_httpDataDir + "/.stream_paused";
}

napi_value JsMarkStreamPaused(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int paused = GetInt(env, args[0], 0);
    if (paused != 0) {
        FILE* f = fopen(PauseMarkerPath().c_str(), "w");
        if (f != nullptr) {
            fputc('1', f);
            fclose(f);
        }
    } else {
        unlink(PauseMarkerPath().c_str());
    }
    return MakeInt(env, 0);
}

napi_value JsIsStreamPaused(napi_env env, napi_callback_info) {
    return MakeInt(env, access(PauseMarkerPath().c_str(), F_OK) == 0 ? 1 : 0);
}

napi_value JsGetLogPath(napi_env env, napi_callback_info) {
    return MakeString(env, mdiag::LogFilePath());
}

napi_value JsGetVersion(napi_env env, napi_callback_info) {
    return MakeString(env, LI_VERSION_STRING);
}

napi_value JsGetBuildInfo(napi_env env, napi_callback_info) {
    std::string s = "{\"core\":\"moonlight-common-c\",\"commit\":\"" MC_COMMIT "\",\"ohosArch\":\"" OHOS_ARCH "\"}";
    return MakeString(env, s);
}

napi_value JsProbeHost(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    AsyncData* d = new AsyncData();
    d->env = env;
    d->host = GetString(env, argc > 0 ? args[0] : nullptr);
    d->timeoutMs = GetInt(env, argc > 1 ? args[1] : nullptr, 3000);

    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "probeHost", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ProbeExecute, GenericComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsTestConnectivity(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    AsyncData* d = new AsyncData();
    d->env = env;
    d->host = GetString(env, argc > 0 ? args[0] : nullptr);
    d->timeoutMs = GetInt(env, argc > 1 ? args[1] : nullptr, 20000);

    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "testConnectivity", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ConnectivityExecute, GenericComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

int HexCharToInt(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool HexToBytes(const std::string& hex, unsigned char* out, size_t outLen) {
    if (hex.size() != outLen * 2) {
        return false;
    }
    for (size_t i = 0; i < outLen; i++) {
        int hi = HexCharToInt(hex[i * 2]);
        int lo = HexCharToInt(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        out[i] = static_cast<unsigned char>((hi << 4) | lo);
    }
    return true;
}

napi_value JsStartConnection(napi_env env, napi_callback_info info) {
    size_t argc = 19;
    napi_value args[19] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    StartData* d = new StartData();
    d->env = env;
    d->address = GetString(env, args[0]);
    d->appVersion = GetString(env, args[1]);
    d->gfeVersion = GetString(env, args[2]);
    d->hasGfe = !d->gfeVersion.empty();
    d->rtspSessionUrl = GetString(env, args[3]);
    d->hasRtsp = !d->rtspSessionUrl.empty();
    d->serverCodecModeSupport = GetInt(env, args[4], 0);
    d->width = GetInt(env, args[5], 1920);
    d->height = GetInt(env, args[6], 1080);
    d->fps = GetInt(env, args[7], 60);
    d->bitrate = GetInt(env, args[8], 20000);
    d->packetSize = GetInt(env, args[9], 1024);
    d->streamingRemotely = GetInt(env, args[10], STREAM_CFG_AUTO);
    d->audioConfiguration = GetInt(env, args[11], 0);
    d->supportedVideoFormats = GetInt(env, args[12], VIDEO_FORMAT_H264);
    d->clientRefreshRateX100 = GetInt(env, args[13], 0);
    std::string keyHex = GetString(env, args[14]);
    std::string ivHex = GetString(env, args[15]);
    d->videoCapabilities = GetInt(env, args[16], 0);
    d->colorSpace = GetInt(env, args[17], 0);
    d->colorRange = GetInt(env, args[18], 0);

    if (!HexToBytes(keyHex, d->riKey, sizeof(d->riKey)) || !HexToBytes(ivHex, d->riIv, sizeof(d->riIv))) {
        mdiag::Log("conn", "invalid riKey/riIv hex (key=%zu iv=%zu)", keyHex.size(), ivHex.size());
        d->result = -1;
        delete d;
        return MakeInt(env, -1);
    }

    if (d->address.empty() || d->appVersion.empty()) {
        mdiag::Log("conn", "startConnection rejected: missing address/appVersion");
        delete d;
        return MakeInt(env, -1);
    }

    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "startConnection", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, StartExecute, GenericComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

struct VoidAsyncData {
    napi_async_work work = nullptr;
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
};

void StopExecute(napi_env, void* data) {
    mdiag::Log("conn", "stop requested (async)");
    StopStatsThread();
    std::lock_guard<std::mutex> lock(g_connMutex);
    // Interrupt first so LiStopConnection doesn't wait for network timeouts.
    LiInterruptConnection();
    LiStopConnection();
}

void InterruptExecute(napi_env, void* data) {
    mdiag::Log("conn", "interrupt requested (async)");
    std::lock_guard<std::mutex> lock(g_connMutex);
    LiInterruptConnection();
}

void VoidAsyncComplete(napi_env env, napi_status, void* data) {
    VoidAsyncData* d = static_cast<VoidAsyncData*>(data);
    if (d->deferred != nullptr) {
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_resolve_deferred(env, d->deferred, undef);
    }
    napi_delete_async_work(env, d->work);
    delete d;
}

napi_value JsStopConnection(napi_env env, napi_callback_info) {
    VoidAsyncData* d = new VoidAsyncData();
    d->env = env;
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "stopConnection", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, StopExecute, VoidAsyncComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsInterruptConnection(napi_env env, napi_callback_info) {
    VoidAsyncData* d = new VoidAsyncData();
    d->env = env;
    napi_value name;
    napi_create_string_utf8(env, "interruptConnection", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, InterruptExecute, VoidAsyncComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value JsGetStageName(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const char* name = LiGetStageName(GetInt(env, args[0], 0));
    return MakeString(env, name ? name : "");
}

napi_value JsGetDiagLogSize(napi_env env, napi_callback_info) {
    napi_value out;
    napi_create_double(env, static_cast<double>(mdiag::LogSizeBytes()), &out);
    return out;
}

napi_value JsClearDiagLog(napi_env env, napi_callback_info) {
    mdiag::ClearLog();
    return nullptr;
}

napi_value JsLogUi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string msg = GetString(env, args[0]);
    mdiag::Log("ui", "%s", msg.c_str());
    return nullptr;
}

napi_value JsSetDiagEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    napi_get_value_bool(env, args[0], &on);
    mdiag::SetEnabled(on);
    return nullptr;
}

napi_value JsSetVideoRange(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    videodec::SetFullRange(GetInt(env, args[0], 0) != 0);
    return nullptr;
}

napi_value JsSendControllerEvent(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int flags = GetInt(env, args[0], 0);
    int lt = GetInt(env, args[1], 0);
    int rt = GetInt(env, args[2], 0);
    int lx = GetInt(env, args[3], 0);
    int ly = GetInt(env, args[4], 0);
    int rx = GetInt(env, args[5], 0);
    int ry = GetInt(env, args[6], 0);
    LiSendControllerEvent(flags, static_cast<unsigned char>(lt), static_cast<unsigned char>(rt),
                          static_cast<short>(lx), static_cast<short>(ly),
                          static_cast<short>(rx), static_cast<short>(ry));
    return nullptr;
}

napi_value JsGetStreamRxBytes(napi_env env, napi_callback_info) {
    napi_value out;
    napi_create_double(env, static_cast<double>(LiDiagGetUdpRxBytes()), &out);
    return out;
}

napi_value JsGetStats(napi_env env, napi_callback_info) {
    uint32_t rtt = 0;
    uint32_t variance = 0;
    bool haveRtt = LiGetEstimatedRttInfo(&rtt, &variance);
    uint64_t lastFrame = g_lastFrameUs.load();
    uint64_t ageMs = lastFrame ? (mdiag::NowUs() - lastFrame) / 1000 : 0;
    char buf[768];
    snprintf(buf, sizeof(buf),
             "{\"connected\":%s,\"framesSubmitted\":%llu,\"bytesSubmitted\":%llu,\"audioPackets\":%llu,"
             "\"rttUs\":%u,\"rttVarianceUs\":%u,\"pendingVideoFrames\":%d,\"pendingAudioMs\":%d,"
             "\"lastFrameAgeMs\":%llu,\"hostLatencyMs\":%.1f,\"videoFormat\":\"%s\",\"width\":%d,\"height\":%d,\"fps\":%d}",
             g_connected.load() ? "true" : "false",
             static_cast<unsigned long long>(g_videoFrames.load()),
             static_cast<unsigned long long>(g_videoBytes.load()),
             static_cast<unsigned long long>(g_audioPackets.load()),
             haveRtt ? rtt : 0, haveRtt ? variance : 0,
             LiGetPendingVideoFrames(), LiGetPendingAudioDuration(),
             static_cast<unsigned long long>(ageMs),
             g_lastHostLatencyTenthsMs.load() / 10.0,
             g_videoFormatName.c_str(), g_videoWidth, g_videoHeight, g_videoFps);
    return MakeString(env, buf);
}

napi_value JsGetEstimatedRtt(napi_env env, napi_callback_info) {
    uint32_t rtt = 0;
    uint32_t variance = 0;
    bool ok = LiGetEstimatedRttInfo(&rtt, &variance);
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"available\":%s,\"rttUs\":%u,\"varianceUs\":%u}",
             ok ? "true" : "false", rtt, variance);
    return MakeString(env, buf);
}

napi_value JsSendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    LiSendMouseMoveEvent(static_cast<short>(GetInt(env, args[0], 0)),
                         static_cast<short>(GetInt(env, args[1], 0)));
    return MakeInt(env, 0);
}

napi_value JsSendMousePosition(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    static std::atomic<uint64_t> moveCount{0};
    int x = GetInt(env, args[0], 0);
    int y = GetInt(env, args[1], 0);
    int rw = GetInt(env, args[2], 1920);
    int rh = GetInt(env, args[3], 1080);
    LiSendMousePositionEvent(static_cast<short>(x), static_cast<short>(y),
                             static_cast<short>(rw), static_cast<short>(rh));
    uint64_t n = moveCount.fetch_add(1) + 1;
    if (n % 40 == 0) {
        mdiag::Log("input", "mouse pos %d,%d ref %dx%d (n=%llu)", x, y, rw, rh,
                   static_cast<unsigned long long>(n));
    }
    return MakeInt(env, 0);
}

napi_value JsSendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int action = GetInt(env, args[0], 0);
    int button = GetInt(env, args[1], 0);
    LiSendMouseButtonEvent(static_cast<char>(action), static_cast<char>(button));
    mdiag::Log("input", "mouse button action=0x%x button=%d", action, button);
    return MakeInt(env, 0);
}

napi_value JsSendMouseScroll(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    LiSendHighResScrollEvent(static_cast<short>(GetInt(env, args[0], 0)));
    return MakeInt(env, 0);
}

napi_value JsSendKeyboard(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    LiSendKeyboardEvent2(static_cast<short>(GetInt(env, args[0], 0)),
                         static_cast<char>(GetInt(env, args[1], 0)),
                         static_cast<char>(GetInt(env, args[2], 0)),
                         static_cast<char>(GetInt(env, args[3], 0)));
    return MakeInt(env, 0);
}

napi_value JsSendTouch(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int ret = LiSendTouchEvent(static_cast<uint8_t>(GetInt(env, args[0], 0)),
                               static_cast<uint32_t>(GetInt(env, args[1], 0)),
                               static_cast<float>(GetInt(env, args[2], 0)),
                               static_cast<float>(GetInt(env, args[3], 0)),
                               static_cast<float>(GetInt(env, args[4], 0)),
                               static_cast<float>(GetInt(env, args[5], 0)),
                               static_cast<float>(GetInt(env, args[6], 0)),
                               static_cast<uint16_t>(GetInt(env, args[7], 0)));
    return MakeInt(env, ret);
}

napi_value JsSendUtf8Text(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string text = GetString(env, args[0]);
    LiSendUtf8TextEvent(text.c_str(), static_cast<unsigned int>(text.size()));
    return MakeInt(env, 0);
}

napi_value JsGetPending(napi_env env, napi_callback_info) {
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"videoFrames\":%d,\"audioMs\":%d}",
             LiGetPendingVideoFrames(), LiGetPendingAudioDuration());
    return MakeString(env, buf);
}

napi_value JsStringifyPortFlags(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int flags = GetInt(env, args[0], 0);
    std::string sep = GetString(env, args[1]);
    if (sep.empty()) {
        sep = ",";
    }
    char out[512];
    LiStringifyPortFlags(static_cast<unsigned int>(flags), sep.c_str(), out, sizeof(out));
    return MakeString(env, out);
}

napi_value JsGetPortFlagsFromStage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeInt(env, static_cast<int32_t>(LiGetPortFlagsFromStage(GetInt(env, args[0], 0))));
}

napi_value JsGetPortFlagsFromTerminationError(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return MakeInt(env, static_cast<int32_t>(LiGetPortFlagsFromTerminationErrorCode(GetInt(env, args[0], 0))));
}

napi_value JsFindExternalAddressIP4(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string host = GetString(env, args[0]);
    int port = GetInt(env, args[1], 3478);
    struct in_addr addr;
    memset(&addr, 0, sizeof(addr));
    int err = LiFindExternalAddressIP4(host.c_str(), static_cast<unsigned short>(port), &addr.s_addr);
    if (err != 0) {
        return MakeString(env, "");
    }
    char text[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &addr, text, sizeof(text));
    return MakeString(env, text);
}

napi_value JsGetLaunchUrlQueryParameters(napi_env env, napi_callback_info) {
    const char* params = LiGetLaunchUrlQueryParameters();
    return MakeString(env, params ? params : "");
}


struct AssetData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_env env = nullptr;
    std::string host;
    int appId = 0;
    std::string bytes;
    std::string error;
};

void AssetComplete(napi_env env, napi_status, void* data) {
    AssetData* d = static_cast<AssetData*>(data);
    if (d->deferred != nullptr) {
        if (!d->error.empty()) {
            napi_value errValue;
            napi_create_string_utf8(env, d->error.c_str(), NAPI_AUTO_LENGTH, &errValue);
            napi_reject_deferred(env, d->deferred, errValue);
        } else {
            napi_value buffer;
            void* raw = nullptr;
            napi_create_arraybuffer(env, d->bytes.size(), &raw, &buffer);
            if (raw != nullptr && !d->bytes.empty()) {
                memcpy(raw, d->bytes.data(), d->bytes.size());
            }
            napi_resolve_deferred(env, d->deferred, buffer);
        }
    }
    napi_delete_async_work(env, d->work);
    delete d;
}

void AssetExecute(napi_env, void* data) {
    AssetData* d = static_cast<AssetData*>(data);
    if (!nvhttp::GetBoxArt(d->host, d->appId, &d->bytes, &d->error)) {
        mdiag::Log("nvhttp", "boxart appid=%d failed: %s", d->appId, d->error.c_str());
    }
}

napi_value JsFetchAsset(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    AssetData* d = new AssetData();
    d->env = env;
    d->host = GetString(env, args[0]);
    d->appId = GetInt(env, args[1], 0);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "fetchAsset", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, AssetExecute, AssetComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsEmitTestEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string msg = GetString(env, args[0]);
    mdiag::Log("app", "ui: %s", msg.c_str());
    Emit("ui", "{\"message\":\"" + mdiag::JsonEscape(msg) + "\"}");
    return MakeInt(env, 0);
}


// ---------------------------------------------------------------------------
// Pairing / NvHTTP async exports
// ---------------------------------------------------------------------------
struct NvAsyncData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_env env = nullptr;
    std::string host;
    std::string pin;
    int appId = 0;
    int width = 1920;
    int height = 1080;
    int fps = 60;
    int bitrate = 20000;
    std::string riKeyHex;
    int riKeyId = 0;
    int virtualDisplay = 0;
    int audioConfiguration = 0x302CA;
    int sops = 1;
    int hostAudio = 0;
    std::string resultJson;
};

void NvStringComplete(napi_env env, napi_status, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    if (d->deferred != nullptr) {
        napi_value value;
        napi_create_string_utf8(env, d->resultJson.c_str(), NAPI_AUTO_LENGTH, &value);
        napi_resolve_deferred(env, d->deferred, value);
    }
    napi_delete_async_work(env, d->work);
    delete d;
}

void PairBeginExecute(napi_env, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    d->resultJson = nvhttp::PairBegin(d->host, 120000);
}

void PairCompleteExecute(napi_env, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    d->resultJson = nvhttp::PairComplete(d->host, d->pin);
}

void HostInfoExecute(napi_env, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    nvhttp::HostInfo info = nvhttp::GetServerInfo(d->host, 5000);
    char buf[1024];
    snprintf(buf, sizeof(buf),
             "{\"online\":%s,\"hostname\":\"%s\",\"appVersion\":\"%s\",\"pairStatus\":%d,"
             "\"httpsPort\":%d,\"serverCodecModeSupport\":%d,\"runningGameId\":%d,\"state\":\"%s\",\"error\":\"%s\"}",
             info.online ? "true" : "false", mdiag::JsonEscape(info.hostname).c_str(),
             mdiag::JsonEscape(info.appVersion).c_str(), info.pairStatus, info.httpsPort,
             info.serverCodecModeSupport, info.runningGameId,
             mdiag::JsonEscape(info.state).c_str(), mdiag::JsonEscape(info.error).c_str());
    d->resultJson = buf;
}

void AppListExecute(napi_env, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    std::string err;
    std::vector<nvhttp::AppEntry> apps = nvhttp::GetAppList(d->host, &err);
    std::string json = "{\"error\":\"" + mdiag::JsonEscape(err) + "\",\"apps\":[";
    for (size_t i = 0; i < apps.size(); i++) {
        if (i > 0) {
            json += ",";
        }
        json += "{\"id\":" + std::to_string(apps[i].id) + ",\"title\":\"" +
                mdiag::JsonEscape(apps[i].title) + "\",\"hdr\":" +
                (apps[i].hdrSupported ? "true" : "false") + "}";
    }
    json += "]}";
    d->resultJson = json;
    mdiag::Log("nvhttp", "applist returned %zu apps err=%s", apps.size(), err.c_str());
}

void LaunchExecute(napi_env, void* data) {
    NvAsyncData* d = static_cast<NvAsyncData*>(data);
    nvhttp::LaunchResult r = nvhttp::LaunchApp(d->host, d->appId, d->width, d->height, d->fps,
                                               d->bitrate, d->riKeyHex, d->riKeyId,
                                               d->virtualDisplay != 0, d->audioConfiguration,
                                               d->sops != 0, d->hostAudio != 0);
    d->resultJson = std::string("{\"ok\":") + (r.ok ? "true" : "false") +
                    ",\"sessionUrl\":\"" + mdiag::JsonEscape(r.sessionUrl) +
                    "\",\"error\":\"" + mdiag::JsonEscape(r.error) + "\"}";
}

napi_value JsPairBegin(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NvAsyncData* d = new NvAsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "pairBegin", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, PairBeginExecute, NvStringComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsPairComplete(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NvAsyncData* d = new NvAsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    d->pin = GetString(env, args[1]);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "pairComplete", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, PairCompleteExecute, NvStringComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsHostInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NvAsyncData* d = new NvAsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "hostInfo", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, HostInfoExecute, NvStringComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsGetAppList(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NvAsyncData* d = new NvAsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "getAppList", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, AppListExecute, NvStringComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsLaunchApp(napi_env env, napi_callback_info info) {
    size_t argc = 12;
    napi_value args[12] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NvAsyncData* d = new NvAsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    d->appId = GetInt(env, args[1], 0);
    d->width = GetInt(env, args[2], 1920);
    d->height = GetInt(env, args[3], 1080);
    d->fps = GetInt(env, args[4], 60);
    d->bitrate = GetInt(env, args[5], 20000);
    d->riKeyHex = GetString(env, args[6]);
    d->riKeyId = GetInt(env, args[7], 0);
    d->virtualDisplay = GetInt(env, args[8], 0);
    d->audioConfiguration = GetInt(env, args[9], 0x302CA);
    d->sops = GetInt(env, args[10], 1);
    d->hostAudio = GetInt(env, args[11], 0);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "launchApp", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, LaunchExecute, NvStringComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

void QuitExecute(napi_env, void* data) {
    AsyncData* d = static_cast<AsyncData*>(data);
    d->resultInt = nvhttp::QuitApp(d->host) ? 1 : 0;
    mdiag::Log("nvhttp", "quit app %s result=%d", d->host.c_str(), d->resultInt);
}

napi_value JsQuitApp(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    AsyncData* d = new AsyncData();
    d->env = env;
    d->host = GetString(env, args[0]);
    napi_value promise;
    napi_create_promise(env, &d->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "quitApp", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, QuitExecute, GenericComplete, d, &d->work);
    napi_queue_async_work(env, d->work);
    return promise;
}

napi_value JsGenerateRiKey(napi_env env, napi_callback_info) {
    unsigned char key[16];
    unsigned char idBytes[4];
    FILE* f = fopen("/dev/urandom", "rb");
    if (f != nullptr) {
        if (fread(key, 1, sizeof(key), f) != sizeof(key) ||
            fread(idBytes, 1, sizeof(idBytes), f) != sizeof(idBytes)) {
            memset(key, 0x5A, sizeof(key));
            memset(idBytes, 0x3C, sizeof(idBytes));
        }
        fclose(f);
    } else {
        memset(key, 0x5A, sizeof(key));
        memset(idBytes, 0x3C, sizeof(idBytes));
    }
    char buf[64];
    char hex[33];
    static const char* kHex = "0123456789ABCDEF";
    for (int i = 0; i < 16; i++) {
        hex[i * 2] = kHex[key[i] >> 4];
        hex[i * 2 + 1] = kHex[key[i] & 0x0F];
    }
    hex[32] = '\0';
    int id = (idBytes[0] << 24) | (idBytes[1] << 16) | (idBytes[2] << 8) | idBytes[3];
    snprintf(buf, sizeof(buf), "%s:%d", hex, id);
    return MakeString(env, buf);
}

} // namespace

static napi_value ModuleInit(napi_env env, napi_value exports) {
    InitCallbacks();

    napi_property_descriptor desc[] = {
            {"init", nullptr, JsInit, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setEventCallback", nullptr, JsSetEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"clearEventCallback", nullptr, JsClearEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setLogDir", nullptr, JsSetLogDir, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getLogPath", nullptr, JsGetLogPath, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setSurfaceId", nullptr, JsSetSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"markStreamPaused", nullptr, JsMarkStreamPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"isStreamPaused", nullptr, JsIsStreamPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getVersion", nullptr, JsGetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getBuildInfo", nullptr, JsGetBuildInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"probeHost", nullptr, JsProbeHost, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"testConnectivity", nullptr, JsTestConnectivity, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"startConnection", nullptr, JsStartConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"stopConnection", nullptr, JsStopConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"interruptConnection", nullptr, JsInterruptConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getStageName", nullptr, JsGetStageName, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getStats", nullptr, JsGetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getStreamRxBytes", nullptr, JsGetStreamRxBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"logUi", nullptr, JsLogUi, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getDiagLogSize", nullptr, JsGetDiagLogSize, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"clearDiagLog", nullptr, JsClearDiagLog, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setDiagEnabled", nullptr, JsSetDiagEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setVideoRange", nullptr, JsSetVideoRange, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendControllerEvent", nullptr, JsSendControllerEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getEstimatedRtt", nullptr, JsGetEstimatedRtt, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendMouseMove", nullptr, JsSendMouseMove, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendMousePosition", nullptr, JsSendMousePosition, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendMouseButton", nullptr, JsSendMouseButton, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendMouseScroll", nullptr, JsSendMouseScroll, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendKeyboard", nullptr, JsSendKeyboard, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendTouch", nullptr, JsSendTouch, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"sendUtf8Text", nullptr, JsSendUtf8Text, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getPending", nullptr, JsGetPending, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"stringifyPortFlags", nullptr, JsStringifyPortFlags, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getPortFlagsFromStage", nullptr, JsGetPortFlagsFromStage, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getPortFlagsFromTerminationError", nullptr, JsGetPortFlagsFromTerminationError, nullptr, nullptr,
                                                                                        nullptr, napi_default, nullptr},
            {"findExternalAddressIP4", nullptr, JsFindExternalAddressIP4, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getLaunchUrlQueryParameters", nullptr, JsGetLaunchUrlQueryParameters, nullptr, nullptr, nullptr,
                                                                                        napi_default, nullptr},
            {"emitTestEvent", nullptr, JsEmitTestEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"pairBegin", nullptr, JsPairBegin, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"pairComplete", nullptr, JsPairComplete, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getHostInfo", nullptr, JsHostInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getAppList", nullptr, JsGetAppList, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"launchApp", nullptr, JsLaunchApp, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"quitApp", nullptr, JsQuitApp, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"generateRiKey", nullptr, JsGenerateRiKey, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"fetchAsset", nullptr, JsFetchAsset, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module g_module = {
        1,
        0,
        nullptr,
        ModuleInit,
        "moonbridge",
        nullptr,
        {0},
};

extern "C" __attribute__((constructor)) void RegisterMoonBridgeModule(void) {
    napi_module_register(&g_module);
}
