#ifndef MOONLIGHT_OHOS_NVHTTP_H
#define MOONLIGHT_OHOS_NVHTTP_H

#include <mbedtls/pk.h>
#include <mbedtls/x509_crt.h>

#include <string>
#include <vector>

namespace nvhttp {

void SetDataDir(const std::string& dir);

bool EnsureClientCert(std::string* errOut);
mbedtls_x509_crt* ClientCrt();
mbedtls_pk_context* ClientKey();

struct HostInfo {
    bool online = false;
    std::string hostname;
    std::string appVersion;
    std::string uniqueId;
    std::string state;
    int pairStatus = 0;
    int httpsPort = 47984;
    int externalPort = 47989;
    int serverCodecModeSupport = 0;
    int runningGameId = 0;
    std::string error;
};

HostInfo GetServerInfo(const std::string& host, int timeoutMs);

struct AppEntry {
    int id = 0;
    std::string title;
    bool hdrSupported = false;
};

std::vector<AppEntry> GetAppList(const std::string& host, std::string* errOut);

// Phase 1: request the server certificate and make the host display its PIN.
// Returns one of: "READY", "ALREADY_PAIRED", "IN_PROGRESS", "FAILED:<reason>"
std::string PairBegin(const std::string& host, int timeoutMs);

// Phase 2: finish pairing with the PIN shown on the host.
// Returns: "PAIRED", "PIN_WRONG", "FAILED:<reason>"
std::string PairComplete(const std::string& host, const std::string& pin);

struct LaunchResult {
    bool ok = false;
    std::string sessionUrl;
    std::string error;
};

LaunchResult LaunchApp(const std::string& host, int appId, int width, int height, int fps,
                       int bitrate, const std::string& riKeyHex, int riKeyId, bool virtualDisplay,
                       int audioConfiguration, bool sops, bool hostAudio);

bool QuitApp(const std::string& host);

// Fetches the box art (JPEG/PNG) for an application over mTLS HTTPS.
bool GetBoxArt(const std::string& host, int appId, std::string* outBytes, std::string* errOut);

} // namespace nvhttp

#endif
