#include "videodec.h"
#include "diag.h"

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <native_window/external_window.h>

#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace videodec {

namespace {

struct PendingFrame {
    std::vector<unsigned char> data;
    int64_t ptsUs = 0;
    bool keyFrame = false;
};

struct FreeBuffer {
    uint32_t index = 0;
    OH_AVBuffer* buffer = nullptr;
};

std::mutex g_mutex;
OH_AVCodec* g_codec = nullptr;
OHNativeWindow* g_window = nullptr;
std::atomic<uint64_t> g_surfaceId{0};
bool g_configured = false;
std::deque<PendingFrame> g_pendingFrames;
std::deque<FreeBuffer> g_freeInput;
int g_width = 0;
int g_height = 0;
std::atomic<uint64_t> g_decodedFrames{0};
bool g_waitingKeyFrame = true;
bool g_fullRange = false;

const char* MimeForFormat(int format) {
    switch (format) {
        case VIDEO_FORMAT_H264: return OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        case VIDEO_FORMAT_H265:
        case VIDEO_FORMAT_H265_MAIN10: return OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
        case VIDEO_FORMAT_AV1_MAIN8:
        case VIDEO_FORMAT_AV1_MAIN10: return OH_AVCODEC_MIMETYPE_VIDEO_AV1;
        default: return nullptr;
    }
}

// Destroys a decoder/window pair. Never call while holding g_mutex: these
// calls may block for a long time and would stall the UI and decode threads.
void DestroyPair(OH_AVCodec* codec, OHNativeWindow* window) {
    if (codec != nullptr) {
        OH_VideoDecoder_Stop(codec);
        OH_VideoDecoder_Destroy(codec);
    }
    if (window != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(window);
    }
}

void PushInputLocked(uint32_t index, OH_AVBuffer* buffer, const PendingFrame& frame) {
    uint8_t* addr = OH_AVBuffer_GetAddr(buffer);
    OH_AVCodec* codec = g_codec;
    if (addr == nullptr || codec == nullptr) {
        if (codec != nullptr) {
            OH_VideoDecoder_PushInputBuffer(codec, index);
        }
        return;
    }
    int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    if (capacity > 0 && static_cast<size_t>(capacity) < frame.data.size()) {
        static std::atomic<uint64_t> warns{0};
        uint64_t w = warns.fetch_add(1) + 1;
        if (w == 1 || w % 100 == 0) {
            mdiag::Log("vdec", "input buffer too small consider drop: need=%zu cap=%d",
                       frame.data.size(), capacity);
        }
        OH_VideoDecoder_PushInputBuffer(codec, index);
        return;
    }
    memcpy(addr, frame.data.data(), frame.data.size());
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pts = frame.ptsUs;
    attr.size = static_cast<int32_t>(frame.data.size());
    attr.flags = frame.keyFrame ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);
    OH_VideoDecoder_PushInputBuffer(codec, index);
}

void DrainLocked() {
    while (!g_pendingFrames.empty() && !g_freeInput.empty()) {
        FreeBuffer fb = g_freeInput.front();
        g_freeInput.pop_front();
        PendingFrame frame = std::move(g_pendingFrames.front());
        g_pendingFrames.pop_front();
        PushInputLocked(fb.index, fb.buffer, frame);
    }
}

void OnError(OH_AVCodec*, int32_t errorCode, void*) {
    mdiag::Log("vdec", "decoder error %d", errorCode);
}

void OnStreamChanged(OH_AVCodec*, OH_AVFormat* format, void*) {
    int32_t width = 0;
    int32_t height = 0;
    if (format != nullptr) {
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &width);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &height);
    }
    mdiag::Log("vdec", "stream changed %dx%d", width, height);
    std::lock_guard<std::mutex> lock(g_mutex);
    g_width = width;
    g_height = height;
}

void OnNeedInputBuffer(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void*) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_configured) {
        return;
    }
    g_freeInput.push_back(FreeBuffer{index, buffer});
    DrainLocked();
}

void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer*, void*) {
    if (codec == nullptr) {
        return;
    }
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (ret != AV_ERR_OK) {
        static std::atomic<uint64_t> fails{0};
        uint64_t f = fails.fetch_add(1) + 1;
        if (f == 1 || f % 100 == 0) {
            mdiag::Log("vdec", "render output failed rc=%d", ret);
        }
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
        return;
    }
    if (g_waitingKeyFrame) {
        g_waitingKeyFrame = false;
        mdiag::Log("vdec", "first decoded frame received");
    }
    uint64_t n = g_decodedFrames.fetch_add(1) + 1;
    if (n == 1 || n % 300 == 0) {
        mdiag::Log("vdec", "rendered frames=%llu", static_cast<unsigned long long>(n));
    }
}

} // namespace

void SetSurfaceId(const std::string& surfaceId) {
    uint64_t id = 0;
    try {
        id = std::stoull(surfaceId);
    } catch (...) {
        id = 0;
    }
    g_surfaceId.store(id);
    mdiag::Log("vdec", "surface id set: %s", surfaceId.c_str());
}

bool IsReady() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_configured && g_codec != nullptr;
}

bool Setup(int videoFormat, int width, int height, int fps) {
    // Detach the old pair first; destroy it outside the lock.
    OH_AVCodec* oldCodec = nullptr;
    OHNativeWindow* oldWindow = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        oldCodec = g_codec;
        oldWindow = g_window;
        g_codec = nullptr;
        g_window = nullptr;
        g_configured = false;
        g_pendingFrames.clear();
        g_freeInput.clear();
    }
    DestroyPair(oldCodec, oldWindow);

    const char* mime = MimeForFormat(videoFormat);
    if (mime == nullptr) {
        mdiag::Log("vdec", "unsupported video format %d", videoFormat);
        return false;
    }
    uint64_t surfaceId = g_surfaceId.load();
    if (surfaceId == 0) {
        mdiag::Log("vdec", "no surface id yet, decoder skipped");
        return false;
    }

    OHNativeWindow* window = nullptr;
    int32_t winRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
    if (winRet != 0 || window == nullptr) {
        mdiag::Log("vdec", "create native window failed: %d", winRet);
        return false;
    }

    OH_AVCodec* codec = OH_VideoDecoder_CreateByMime(mime);
    if (codec == nullptr) {
        mdiag::Log("vdec", "create decoder failed for %s", mime);
        OH_NativeWindow_DestroyNativeWindow(window);
        return false;
    }

    OH_AVCodecCallback cb;
    cb.onError = OnError;
    cb.onStreamChanged = OnStreamChanged;
    cb.onNeedInputBuffer = OnNeedInputBuffer;
    cb.onNewOutputBuffer = OnNewOutputBuffer;
    if (OH_VideoDecoder_RegisterCallback(codec, cb, nullptr) != AV_ERR_OK) {
        mdiag::Log("vdec", "register callback failed");
        DestroyPair(codec, window);
        return false;
    }

    OH_AVFormat* format = OH_AVFormat_Create();
    if (format == nullptr) {
        DestroyPair(codec, window);
        return false;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, fps);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_RANGE_FLAG, g_fullRange ? 1 : 0);
    if (videoFormat == VIDEO_FORMAT_H265_MAIN10) {
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, static_cast<int32_t>(HEVC_PROFILE_MAIN_10));
    }
    int32_t ret = OH_VideoDecoder_Configure(codec, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        mdiag::Log("vdec", "configure failed: %d", ret);
        DestroyPair(codec, window);
        return false;
    }
    if (OH_VideoDecoder_SetSurface(codec, window) != AV_ERR_OK ||
        OH_VideoDecoder_Prepare(codec) != AV_ERR_OK) {
        mdiag::Log("vdec", "set surface/prepare failed");
        DestroyPair(codec, window);
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_codec = codec;
        g_window = window;
        g_width = width;
        g_height = height;
        g_configured = true;
        g_waitingKeyFrame = true;
        g_decodedFrames.store(0);
    }

    if (OH_VideoDecoder_Start(codec) != AV_ERR_OK) {
        mdiag::Log("vdec", "start failed");
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_codec = nullptr;
            g_window = nullptr;
            g_configured = false;
        }
        DestroyPair(codec, window);
        return false;
    }

    mdiag::Log("vdec", "decoder started %s %dx%d@%d surface=%llu",
               mime, width, height, fps, static_cast<unsigned long long>(surfaceId));
    return true;
}

bool Submit(PDECODE_UNIT du) {
    if (du == nullptr || du->fullLength <= 0) {
        return true;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_configured || g_codec == nullptr) {
        return true;
    }
    if (g_waitingKeyFrame && du->frameType != FRAME_TYPE_IDR) {
        static std::atomic<uint64_t> drops{0};
        uint64_t d = drops.fetch_add(1) + 1;
        if (d == 1 || d % 300 == 0) {
            mdiag::Log("vdec", "waiting for keyframe, dropped non-IDR (count=%llu)",
                       static_cast<unsigned long long>(d));
        }
        return false;
    }
    PendingFrame frame;
    frame.ptsUs = static_cast<int64_t>(du->presentationTimeUs);
    frame.keyFrame = du->frameType == FRAME_TYPE_IDR;
    frame.data.resize(static_cast<size_t>(du->fullLength));
    size_t offset = 0;
    for (PLENTRY entry = du->bufferList; entry != nullptr; entry = entry->next) {
        if (offset + entry->length > frame.data.size()) {
            break;
        }
        memcpy(frame.data.data() + offset, entry->data, entry->length);
        offset += entry->length;
    }
    if (offset == 0) {
        return true;
    }
    if (g_pendingFrames.size() >= 2) {
        g_pendingFrames.pop_front();
    }
    g_pendingFrames.push_back(std::move(frame));
    DrainLocked();
    return true;
}

void SetFullRange(bool full) {
    g_fullRange = full;
}

void Start() {
}

void Stop() {
    OH_AVCodec* codec = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        codec = g_codec;
    }
    if (codec != nullptr) {
        OH_VideoDecoder_Flush(codec);
    }
}

void Cleanup() {
    OH_AVCodec* codec = nullptr;
    OHNativeWindow* window = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        codec = g_codec;
        window = g_window;
        g_codec = nullptr;
        g_window = nullptr;
        g_configured = false;
        g_pendingFrames.clear();
        g_freeInput.clear();
    }
    DestroyPair(codec, window);
}

} // namespace videodec
