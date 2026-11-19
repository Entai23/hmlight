#include "audiodec.h"
#include "diag.h"

#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostream_base.h>
#include <multimedia/native_audio_channel_layout.h>

#include <opus_multistream.h>

#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

namespace audiodec {

namespace {

std::mutex g_mutex;
OpusMSDecoder* g_decoder = nullptr;
OH_AudioRenderer* g_renderer = nullptr;
OH_AudioStreamBuilder* g_builder = nullptr;

int g_sampleRate = 48000;
int g_channels = 2;
int g_samplesPerFrame = 960;

std::deque<int16_t> g_pcmQueue;
size_t g_maxQueuedSamples = 0;
size_t g_prebufferSamples = 0;
std::vector<int16_t> g_decodeBuffer;
bool g_started = false;
bool g_prebuffered = false;
std::atomic<bool> g_active{false};
std::atomic<uint64_t> g_underruns{0};
std::atomic<uint64_t> g_callbacks{0};

OH_AudioData_Callback_Result OnWriteData(OH_AudioRenderer*, void*, void* audioData,
                                         int32_t audioDataSize) {
    int16_t* out = static_cast<int16_t*>(audioData);
    size_t frames = static_cast<size_t>(audioDataSize) / sizeof(int16_t);
    if (!g_active.load()) {
        memset(out, 0, frames * sizeof(int16_t));
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_prebuffered) {
        if (g_pcmQueue.size() < g_prebufferSamples) {
            memset(out, 0, frames * sizeof(int16_t));
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        g_prebuffered = true;
    }
    size_t copied = 0;
    while (copied < frames && !g_pcmQueue.empty()) {
        out[copied++] = g_pcmQueue.front();
        g_pcmQueue.pop_front();
    }
    if (copied < frames) {
        memset(out + copied, 0, (frames - copied) * sizeof(int16_t));
        g_underruns.fetch_add(1);
        // Sustained starvation: rebuild the jitter buffer to avoid constant crackle.
        if (g_pcmQueue.empty() && g_underruns.load() % 200 == 0) {
            g_prebuffered = false;
        }
    }
    uint64_t calls = g_callbacks.fetch_add(1) + 1;
    if (calls % 2000 == 0) {
        mdiag::Log("audio", "callback=%llu underruns=%llu queued=%zu",
                   static_cast<unsigned long long>(calls),
                   static_cast<unsigned long long>(g_underruns.load()),
                   g_pcmQueue.size());
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void ReleaseLocked() {
    if (g_renderer != nullptr) {
        OH_AudioRenderer_Stop(g_renderer);
        OH_AudioRenderer_Release(g_renderer);
        g_renderer = nullptr;
    }
    if (g_builder != nullptr) {
        OH_AudioStreamBuilder_Destroy(g_builder);
        g_builder = nullptr;
    }
    if (g_decoder != nullptr) {
        opus_multistream_decoder_destroy(g_decoder);
        g_decoder = nullptr;
    }
    g_pcmQueue.clear();
    g_started = false;
}

} // namespace

bool Init(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, int flags) {
    std::lock_guard<std::mutex> lock(g_mutex);
    ReleaseLocked();
    if (opusConfig == nullptr) {
        return false;
    }

    g_sampleRate = opusConfig->sampleRate;
    g_channels = opusConfig->channelCount;
    g_samplesPerFrame = opusConfig->samplesPerFrame;
    g_maxQueuedSamples = static_cast<size_t>(g_sampleRate) * g_channels / 4;
    g_prebufferSamples = static_cast<size_t>(g_sampleRate) * g_channels * 60 / 1000;
    g_prebuffered = false;
    g_underruns.store(0);
    g_callbacks.store(0);
    g_decodeBuffer.resize(static_cast<size_t>(g_samplesPerFrame) * g_channels);

    int err = 0;
    g_decoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                opusConfig->channelCount,
                                                opusConfig->streams,
                                                opusConfig->coupledStreams,
                                                opusConfig->mapping,
                                                &err);
    if (g_decoder == nullptr || err != OPUS_OK) {
        mdiag::Log("audio", "opus decoder create failed err=%d", err);
        g_decoder = nullptr;
        return false;
    }

    if (OH_AudioStreamBuilder_Create(&g_builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS) {
        mdiag::Log("audio", "audio builder create failed");
        ReleaseLocked();
        return false;
    }

    OH_AudioStreamBuilder_SetSamplingRate(g_builder, opusConfig->sampleRate);
    OH_AudioStreamBuilder_SetChannelCount(g_builder, opusConfig->channelCount);
    OH_AudioStreamBuilder_SetSampleFormat(g_builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(g_builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetRendererInfo(g_builder, AUDIOSTREAM_USAGE_GAME);
    if (opusConfig->channelCount == 2) {
        OH_AudioStreamBuilder_SetChannelLayout(g_builder, CH_LAYOUT_STEREO);
    } else if (opusConfig->channelCount == 6) {
        OH_AudioStreamBuilder_SetChannelLayout(g_builder, CH_LAYOUT_5POINT1);
    } else if (opusConfig->channelCount == 8) {
        OH_AudioStreamBuilder_SetChannelLayout(g_builder, CH_LAYOUT_7POINT1);
    }
    OH_AudioStreamBuilder_SetLatencyMode(g_builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(g_builder, OnWriteData, nullptr);

    if (OH_AudioStreamBuilder_GenerateRenderer(g_builder, &g_renderer) != AUDIOSTREAM_SUCCESS ||
        g_renderer == nullptr) {
        mdiag::Log("audio", "generate audio renderer failed");
        ReleaseLocked();
        return false;
    }

    g_active.store(true);
    mdiag::Log("audio", "renderer ready rate=%d ch=%d frame=%d prebuffer=%zu",
               g_sampleRate, g_channels, g_samplesPerFrame, g_prebufferSamples);
    return true;
}

void Start() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_renderer != nullptr && !g_started) {
        OH_AudioRenderer_Start(g_renderer);
        g_started = true;
        mdiag::Log("audio", "renderer started");
    }
}

void Stop() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_renderer != nullptr && g_started) {
        OH_AudioRenderer_Stop(g_renderer);
        g_started = false;
    }
}

void Cleanup() {
    OH_AudioRenderer* renderer = nullptr;
    OH_AudioStreamBuilder* builder = nullptr;
    OpusMSDecoder* decoder = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_active.store(false);
        g_prebuffered = false;
        g_pcmQueue.clear();
        renderer = g_renderer;
        builder = g_builder;
        decoder = g_decoder;
        g_renderer = nullptr;
        g_builder = nullptr;
        g_decoder = nullptr;
        g_started = false;
    }
    if (renderer != nullptr) {
        OH_AudioRenderer_Stop(renderer);
        OH_AudioRenderer_Release(renderer);
    }
    if (builder != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder);
    }
    if (decoder != nullptr) {
        opus_multistream_decoder_destroy(decoder);
    }
}

void DecodeAndPlaySample(char* sampleData, int sampleLength) {
    if (sampleData == nullptr || sampleLength <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_decoder == nullptr) {
        return;
    }
    int decoded = opus_multistream_decode(g_decoder,
                                          reinterpret_cast<const unsigned char*>(sampleData),
                                          sampleLength,
                                          g_decodeBuffer.data(),
                                          g_samplesPerFrame,
                                          0);
    if (decoded <= 0) {
        return;
    }
    size_t samples = static_cast<size_t>(decoded) * g_channels;
    // Bound latency: drop the oldest audio if the queue grows too large.
    if (g_pcmQueue.size() + samples > g_maxQueuedSamples) {
        size_t drop = g_pcmQueue.size() + samples - g_maxQueuedSamples;
        if (drop >= g_pcmQueue.size()) {
            g_pcmQueue.clear();
        } else {
            for (size_t i = 0; i < drop; i++) {
                g_pcmQueue.pop_front();
            }
        }
    }
    for (size_t i = 0; i < samples; i++) {
        g_pcmQueue.push_back(g_decodeBuffer[i]);
    }
}

} // namespace audiodec
