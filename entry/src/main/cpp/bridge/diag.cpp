#include "diag.h"

#include <hilog/log.h>

#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <atomic>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace mdiag {

namespace {
static long CurrentTid() { return static_cast<long>(syscall(SYS_gettid)); }
std::mutex g_mutex;
FILE* g_file = nullptr;
std::string g_path;
std::atomic<bool> g_enabled{false};
constexpr const char* kTag = "MoonPort";
constexpr unsigned int kDomain = 0xD002;
} // namespace

static void HilogLine(int level, const char* line) {
    OH_LOG_Print(LOG_APP, static_cast<LogLevel>(level), kDomain, kTag, "%{public}s", line);
}

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 16);
    for (char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

void SetLogDir(const std::string& dir) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file) {
        fclose(g_file);
        g_file = nullptr;
    }
    mkdir(dir.c_str(), 0775);
    g_path = dir + "/moonlight_native.jsonl";
    if (!g_enabled.load()) {
        return;
    }
    g_file = fopen(g_path.c_str(), "a");
    if (g_file) {
        setvbuf(g_file, nullptr, _IOLBF, 0);
        HilogLine(LOG_INFO, ("diag log file: " + g_path).c_str());
    } else {
        HilogLine(LOG_ERROR, ("diag log file open failed: " + g_path).c_str());
    }
}

std::string LogFilePath() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_path;
}

uint64_t NowUs() {
    using namespace std::chrono;
    return static_cast<uint64_t>(
            duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
}

static void WriteLineUnlocked(const std::string& line, int level) {
    HilogLine(level, line.c_str());
    if (g_file) {
        fwrite(line.data(), 1, line.size(), g_file);
        fputc('\n', g_file);
        fflush(g_file);
    }
}

namespace {
std::string g_lastMsg;
uint64_t g_lastLogUs = 0;
int g_suppressed = 0;
} // namespace

void SetEnabled(bool on) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (on == g_enabled.load()) {
        return;
    }
    g_enabled.store(on);
    if (!on) {
        if (g_file) {
            fclose(g_file);
            g_file = nullptr;
        }
        return;
    }
    if (g_file == nullptr && !g_path.empty()) {
        g_file = fopen(g_path.c_str(), "a");
        if (g_file) {
            setvbuf(g_file, nullptr, _IOLBF, 0);
        }
    }
}

void Log(const char* category, const char* fmt, ...) {
    if (!g_enabled.load()) {
        return;
    }
    char msg[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    char head[160];
    snprintf(head, sizeof(head), "{\"ts\":%llu,\"tid\":%ld,\"cat\":\"%s\",\"msg\":\"",
             static_cast<unsigned long long>(NowUs() / 1000),
             CurrentTid(),
             category ? category : "app");

    std::lock_guard<std::mutex> lock(g_mutex);
    uint64_t now = NowUs();
    if (msg == g_lastMsg && now - g_lastLogUs < 300000) {
        g_suppressed++;
        return;
    }
    if (g_suppressed > 0) {
        char note[96];
        snprintf(note, sizeof(note), "{\"ts\":%llu,\"cat\":\"diag\",\"msg\":\"suppressed %d repeated msgs\"}",
                 static_cast<unsigned long long>(now / 1000), g_suppressed);
        WriteLineUnlocked(note, LOG_DEBUG);
        g_suppressed = 0;
    }
    g_lastMsg = msg;
    g_lastLogUs = now;
    std::string line(head);
    line += JsonEscape(msg);
    line += "\"}";
    WriteLineUnlocked(line, LOG_INFO);
}

void EventJson(const char* category, const std::string& jsonFields) {
    if (!g_enabled.load()) {
        return;
    }
    char head[160];
    snprintf(head, sizeof(head), "{\"ts\":%llu,\"tid\":%ld,\"cat\":\"%s\"",
             static_cast<unsigned long long>(NowUs() / 1000),
             CurrentTid(),
             category ? category : "event");

    std::lock_guard<std::mutex> lock(g_mutex);
    std::string line(head);
    if (!jsonFields.empty()) {
        line += ",";
        line += jsonFields;
    }
    line += "}";
    WriteLineUnlocked(line, LOG_INFO);
}

} // namespace mdiag

namespace mdiag {

uint64_t LogSizeBytes() {
    std::lock_guard<std::mutex> lock(g_mutex);
    struct stat st;
    if (g_path.empty() || stat(g_path.c_str(), &st) != 0) {
        return 0;
    }
    return static_cast<uint64_t>(st.st_size);
}

void ClearLog() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file) {
        fclose(g_file);
        g_file = nullptr;
    }
    if (!g_path.empty()) {
        unlink(g_path.c_str());
        if (g_enabled.load()) {
            g_file = fopen(g_path.c_str(), "a");
            if (g_file) {
                setvbuf(g_file, nullptr, _IOLBF, 0);
            }
        }
    }
}

} // namespace mdiag
