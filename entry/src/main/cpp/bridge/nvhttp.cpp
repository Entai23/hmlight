#include "nvhttp.h"
#include "diag.h"

#include <mbedtls/aes.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/md.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/rsa.h>
#include <mbedtls/sha1.h>
#include <mbedtls/sha256.h>
#include <mbedtls/ssl.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <mutex>
#include <vector>

namespace nvhttp {

namespace {

std::recursive_mutex g_mutex;
std::string g_dataDir;
bool g_certReady = false;
mbedtls_x509_crt g_clientCrt;
mbedtls_pk_context g_clientKey;
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_ctr;
bool g_rngReady = false;

struct PairSession {
    bool active = false;
    std::string host;
    bool useSha256 = true;
    std::string uniqueId;
    unsigned char salt[16] = {0};
    unsigned char aesKey[16] = {0};
    unsigned char randomChallenge[16] = {0};
    mbedtls_x509_crt serverCrt;
    bool serverCrtValid = false;
};
PairSession g_pair;

struct HttpResult {
    int status = 0;
    std::string body;
    std::string error;
};

int RngCb(void*, unsigned char* out, size_t len) {
    return mbedtls_ctr_drbg_random(&g_ctr, out, len);
}

bool EnsureRng() {
    if (g_rngReady) {
        return true;
    }
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_ctr);
    const char* pers = "moonlight-ohos-nvhttp";
    if (mbedtls_ctr_drbg_seed(&g_ctr, mbedtls_entropy_func, &g_entropy,
                              reinterpret_cast<const unsigned char*>(pers), strlen(pers)) != 0) {
        return false;
    }
    g_rngReady = true;
    return true;
}

std::string Hex(const unsigned char* data, size_t len) {
    static const char* kHex = "0123456789ABCDEF";
    std::string out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; i++) {
        out.push_back(kHex[data[i] >> 4]);
        out.push_back(kHex[data[i] & 0x0F]);
    }
    return out;
}

bool Unhex(const std::string& text, std::vector<unsigned char>& out) {
    if (text.size() % 2 != 0) {
        return false;
    }
    out.resize(text.size() / 2);
    for (size_t i = 0; i < out.size(); i++) {
        auto val = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = val(text[i * 2]);
        int lo = val(text[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        out[i] = static_cast<unsigned char>((hi << 4) | lo);
    }
    return true;
}

void RandomBytes(unsigned char* out, size_t len) {
    mbedtls_ctr_drbg_random(&g_ctr, out, len);
}

std::string RandomUuidHex() {
    unsigned char raw[16];
    RandomBytes(raw, sizeof(raw));
    return Hex(raw, sizeof(raw));
}

std::string HexEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() * 3);
    for (unsigned char c : in) {
        char buf[4];
        snprintf(buf, sizeof(buf), "%%%02X", c);
        out += buf;
    }
    return out;
}

std::string XmlTag(const std::string& xml, const char* tag) {
    std::string open = std::string("<") + tag + ">";
    size_t start = xml.find(open);
    if (start == std::string::npos) {
        return std::string();
    }
    start += open.size();
    size_t end = xml.find(std::string("</") + tag + ">", start);
    if (end == std::string::npos) {
        return std::string();
    }
    return xml.substr(start, end - start);
}

std::string XmlAttr(const std::string& xml, const char* attr) {
    std::string key = std::string(attr) + "=\"";
    size_t start = xml.find(key);
    if (start == std::string::npos) {
        return std::string();
    }
    start += key.size();
    size_t end = xml.find('"', start);
    if (end == std::string::npos) {
        return std::string();
    }
    return xml.substr(start, end - start);
}

// ---------------------------------------------------------------------------
// HTTP client
// ---------------------------------------------------------------------------
std::string BuildPath(const std::string& path, const std::string& query,
                      const std::string& uniqueId) {
    std::string url = "/" + path + "?uniqueid=" + uniqueId + "&uuid=" + RandomUuidHex();
    if (!query.empty()) {
        url += "&" + query;
    }
    return url;
}

HttpResult ParseResponse(const std::string& raw) {
    HttpResult result;
    if (raw.rfind("HTTP/1.", 0) != 0) {
        result.error = raw.empty() ? "empty_response" : "bad_status_line";
        return result;
    }
    size_t lineEnd = raw.find("\r\n");
    std::string statusLine = raw.substr(0, lineEnd);
    size_t sp = statusLine.find(' ');
    if (sp != std::string::npos) {
        result.status = atoi(statusLine.c_str() + sp + 1);
    }
    size_t headerEnd = raw.find("\r\n\r\n");
    result.body = headerEnd != std::string::npos ? raw.substr(headerEnd + 4) : std::string();
    return result;
}

HttpResult HttpGetPlain(const std::string& host, int port, const std::string& url, int timeoutMs) {
    HttpResult result;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), portStr, &hints, &res) != 0 || res == nullptr) {
        result.error = "getaddrinfo";
        return result;
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
        result.error = "connect";
        return result;
    }

    char req[8192];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUser-Agent: Moonlight-HarmonyOS/0.1\r\n"
             "Accept: */*\r\nConnection: close\r\n\r\n",
             url.c_str(), host.c_str(), port);
    mdiag::Log("nvhttp", "plain request bytes=%zu head=%.72s", strlen(req), req);
    {
        size_t total = strlen(req);
        size_t sent = 0;
        while (sent < total) {
            ssize_t n = send(fd, req + sent, total - sent, 0);
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                result.error = "send";
                close(fd);
                return result;
            }
            sent += static_cast<size_t>(n);
        }
    }

    std::string raw;
    char buf[2048];
    uint64_t recvStart = static_cast<uint64_t>(time(nullptr));
    while (raw.size() < 16u * 1024u * 1024u) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            mdiag::Log("nvhttp", "recv ret=%zd errno=%d after=%llds raw=%zu timeoutMs=%d",
                       n, errno, static_cast<long long>(time(nullptr) - recvStart),
                       raw.size(), timeoutMs);
            break;
        }
        raw.append(buf, static_cast<size_t>(n));
    }
    close(fd);
    return ParseResponse(raw);
}

HttpResult HttpGetTls(const std::string& host, int port, const std::string& url, int timeoutMs) {
    HttpResult result;
    mbedtls_net_context server;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;

    mbedtls_net_init(&server);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);

    do {
        int rc = mbedtls_net_connect(&server, host.c_str(), std::to_string(port).c_str(),
                                     MBEDTLS_NET_PROTO_TCP);
        if (rc != 0) {
            result.error = "connect";
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
            result.error = "ssl_config";
            break;
        }
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_rng(&conf, RngCb, nullptr);
        if (g_certReady) {
            mbedtls_ssl_conf_own_cert(&conf, &g_clientCrt, &g_clientKey);
        }
        rc = mbedtls_ssl_setup(&ssl, &conf);
        if (rc != 0) {
            result.error = "ssl_setup";
            break;
        }
        mbedtls_ssl_set_hostname(&ssl, host.c_str());
        mbedtls_ssl_set_bio(&ssl, &server, mbedtls_net_send, mbedtls_net_recv, nullptr);

        rc = mbedtls_ssl_handshake(&ssl);
        if (rc != 0) {
            char err[128] = {0};
            mbedtls_strerror(rc, err, sizeof(err));
            result.error = std::string("handshake:") + err;
            break;
        }

        char req[8192];
        snprintf(req, sizeof(req), "GET %s HTTP/1.0\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
                 url.c_str(), host.c_str(), port);
        {
            size_t total = strlen(req);
            size_t sent = 0;
            while (sent < total) {
                rc = mbedtls_ssl_write(&ssl, reinterpret_cast<const unsigned char*>(req + sent),
                                       total - sent);
                if (rc <= 0) {
                    result.error = "write";
                    break;
                }
                sent += static_cast<size_t>(rc);
            }
            if (sent < total) {
                break;
            }
        }

        std::string raw;
        char buf[2048];
        uint64_t deadline = mdiag::NowUs() + static_cast<uint64_t>(timeoutMs) * 1000;
        // Box art can be several hundred KB; the old 64 KB cap truncated
        // posters and produced a white band at the bottom of the image.
        while (raw.size() < 16u * 1024u * 1024u) {
            int n = mbedtls_ssl_read(&ssl, reinterpret_cast<unsigned char*>(buf), sizeof(buf));
            if (n > 0) {
                raw.append(buf, static_cast<size_t>(n));
                continue;
            }
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
                // Socket timeout / interrupted syscall: keep waiting until the
                // overall deadline instead of treating it as an empty response.
                if (mdiag::NowUs() > deadline) {
                    break;
                }
                usleep(2000);
                continue;
            }
            break;
        }
        result = ParseResponse(raw);
    } while (false);

    mbedtls_ssl_close_notify(&ssl);
    mbedtls_net_free(&server);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    return result;
}

HttpResult HttpGet(const std::string& host, int port, bool tls, const std::string& path,
                   const std::string& query, int timeoutMs,
                   const std::string& uniqueId = "0123456789ABCDEF") {
    std::string url = BuildPath(path, query, uniqueId);
    HttpResult r = tls ? HttpGetTls(host, port, url, timeoutMs) : HttpGetPlain(host, port, url, timeoutMs);
    mdiag::Log("nvhttp", "%s %s:%d/%s (query %zu, url %zu bytes) -> status=%d err=%s len=%zu",
               tls ? "https" : "http", host.c_str(), port, path.c_str(), query.size(), url.size(),
               r.status, r.error.c_str(), r.body.size());
    return r;
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------
void HashData(bool sha256, const unsigned char* data, size_t len, unsigned char* out, size_t* outLen) {
    if (sha256) {
        mbedtls_sha256(data, len, out, 0);
        *outLen = 32;
    } else {
        mbedtls_sha1(data, len, out);
        *outLen = 20;
    }
}

std::vector<unsigned char> AesEcb(bool encrypt, const unsigned char* key,
                                  const std::vector<unsigned char>& input) {
    std::vector<unsigned char> padded = input;
    size_t rounded = (padded.size() + 15) & ~static_cast<size_t>(15);
    padded.resize(rounded, 0);

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    if (encrypt) {
        mbedtls_aes_setkey_enc(&aes, key, 128);
    } else {
        mbedtls_aes_setkey_dec(&aes, key, 128);
    }

    std::vector<unsigned char> out(rounded);
    for (size_t offset = 0; offset < rounded; offset += 16) {
        mbedtls_aes_crypt_ecb(&aes, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
                              padded.data() + offset, out.data() + offset);
    }
    mbedtls_aes_free(&aes);
    return out;
}

std::vector<unsigned char> SignSha256(const std::vector<unsigned char>& data) {
    unsigned char hash[32];
    mbedtls_sha256(data.data(), data.size(), hash, 0);
    unsigned char sig[512];
    size_t sigLen = 0;
    if (mbedtls_pk_sign(&g_clientKey, MBEDTLS_MD_SHA256, hash, sizeof(hash),
                        sig, sizeof(sig), &sigLen, RngCb, nullptr) != 0) {
        return std::vector<unsigned char>();
    }
    return std::vector<unsigned char>(sig, sig + sigLen);
}

bool VerifySha256(mbedtls_pk_context* pk, const unsigned char* data, size_t len,
                  const unsigned char* sig, size_t sigLen) {
    unsigned char hash[32];
    mbedtls_sha256(data, len, hash, 0);
    return mbedtls_pk_verify(pk, MBEDTLS_MD_SHA256, hash, sizeof(hash), sig, sigLen) == 0;
}

bool PemHex(const std::string& path, std::string* hexOut) {
    FILE* f = fopen(path.c_str(), "r");
    if (f == nullptr) {
        return false;
    }
    std::string pem;
    char buf[1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        pem.append(buf, n);
    }
    fclose(f);
    // Sunshine requires UNIX line endings in the client certificate PEM.
    std::string lf;
    lf.reserve(pem.size());
    for (char c : pem) {
        if (c != '\r') {
            lf.push_back(c);
        }
    }
    *hexOut = Hex(reinterpret_cast<const unsigned char*>(lf.data()), lf.size());
    return true;
}

// ---------------------------------------------------------------------------
// Client certificate
// ---------------------------------------------------------------------------
bool GenerateClientCert(const std::string& dir, std::string* errOut) {
    mbedtls_pk_context key;
    mbedtls_x509write_cert crt;
    mbedtls_pk_init(&key);
    mbedtls_x509write_crt_init(&crt);

    bool ok = false;
    char pemBuf[8192];
    std::string keyPath = dir + "/client_v2.key";
    std::string certPath = dir + "/client_v2.crt";

    do {
        int rc = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
        if (rc != 0) {
            *errOut = "pk_setup";
            break;
        }
        rc = mbedtls_rsa_gen_key(mbedtls_pk_rsa(key), RngCb, nullptr, 2048, 65537);
        if (rc != 0) {
            *errOut = "rsa_gen";
            break;
        }

        mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&crt, &key);
        mbedtls_x509write_crt_set_issuer_key(&crt, &key);
        if (mbedtls_x509write_crt_set_subject_name(&crt, "CN=NVIDIA GameStream Client") != 0 ||
            mbedtls_x509write_crt_set_issuer_name(&crt, "CN=NVIDIA GameStream Client") != 0) {
            *errOut = "crt_name";
            break;
        }
        unsigned char serial[4] = {0x4E, 0x56, 0x49, 0x44};
        mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial));
        mbedtls_x509write_crt_set_validity(&crt, "20200101000000", "20491231235959");

        memset(pemBuf, 0, sizeof(pemBuf));
        rc = mbedtls_x509write_crt_pem(&crt, reinterpret_cast<unsigned char*>(pemBuf),
                                       sizeof(pemBuf) - 1, RngCb, nullptr);
        if (rc != 0) {
            *errOut = "crt_pem";
            break;
        }
        FILE* f = fopen(certPath.c_str(), "w");
        if (f == nullptr) {
            *errOut = "open_crt";
            break;
        }
        fputs(pemBuf, f);
        fclose(f);

        memset(pemBuf, 0, sizeof(pemBuf));
        rc = mbedtls_pk_write_key_pem(&key, reinterpret_cast<unsigned char*>(pemBuf), sizeof(pemBuf) - 1);
        if (rc != 0) {
            *errOut = "key_pem";
            break;
        }
        f = fopen(keyPath.c_str(), "w");
        if (f == nullptr) {
            *errOut = "open_key";
            break;
        }
        fputs(pemBuf, f);
        fclose(f);
        chmod(keyPath.c_str(), 0600);
        ok = true;
    } while (false);

    mbedtls_x509write_crt_free(&crt);
    mbedtls_pk_free(&key);
    return ok;
}

} // namespace

void SetDataDir(const std::string& dir) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    g_dataDir = dir;
}

bool EnsureClientCert(std::string* errOut) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    if (g_certReady) {
        return true;
    }
    if (g_dataDir.empty() || !EnsureRng()) {
        if (errOut) *errOut = "no_datadir_or_rng";
        return false;
    }

    std::string certPath = g_dataDir + "/client_v2.crt";
    std::string keyPath = g_dataDir + "/client_v2.key";

    mbedtls_x509_crt_init(&g_clientCrt);
    mbedtls_pk_init(&g_clientKey);

    bool loaded = false;
    if (access(certPath.c_str(), F_OK) == 0 && access(keyPath.c_str(), F_OK) == 0) {
        loaded = mbedtls_x509_crt_parse_file(&g_clientCrt, certPath.c_str()) == 0 &&
                 mbedtls_pk_parse_keyfile(&g_clientKey, keyPath.c_str(), nullptr, RngCb, nullptr) == 0;
    }
    if (!loaded) {
        mbedtls_x509_crt_free(&g_clientCrt);
        mbedtls_pk_free(&g_clientKey);
        mbedtls_x509_crt_init(&g_clientCrt);
        mbedtls_pk_init(&g_clientKey);
        std::string err;
        if (!GenerateClientCert(g_dataDir, &err)) {
            if (errOut) *errOut = err;
            mdiag::Log("cert", "client cert generation failed: %s", err.c_str());
            return false;
        }
        if (mbedtls_x509_crt_parse_file(&g_clientCrt, certPath.c_str()) != 0 ||
            mbedtls_pk_parse_keyfile(&g_clientKey, keyPath.c_str(), nullptr, RngCb, nullptr) != 0) {
            if (errOut) *errOut = "reload";
            return false;
        }
        mdiag::Log("cert", "generated client certificate (CN=NVIDIA GameStream Client)");
    } else {
        mdiag::Log("cert", "loaded client certificate");
    }
    g_certReady = true;
    return true;
}

mbedtls_x509_crt* ClientCrt() {
    return &g_clientCrt;
}

mbedtls_pk_context* ClientKey() {
    return &g_clientKey;
}

HostInfo GetServerInfo(const std::string& host, int timeoutMs) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    HostInfo info;
    if (!EnsureRng()) {
        info.error = "rng";
        return info;
    }
    // HTTPS reports the real PairStatus; plain HTTP always reports 0.
    HttpResult r;
    if (EnsureClientCert(nullptr)) {
        r = HttpGet(host, 47984, true, "serverinfo", "", timeoutMs);
        std::string statusCode = XmlAttr(r.body, "status_code");
        if (r.status == 200 && !statusCode.empty() && statusCode != "200") {
            mdiag::Log("nvhttp", "https serverinfo status_code=%s, falling back to http",
                       statusCode.c_str());
            r = HttpResult();
        }
    }
    if (r.status != 200) {
        r = HttpGet(host, 47989, false, "serverinfo", "", timeoutMs);
    }
    if (r.status != 200) {
        info.error = r.error.empty() ? ("http_" + std::to_string(r.status)) : r.error;
        return info;
    }
    info.online = true;
    info.hostname = XmlTag(r.body, "hostname");
    info.appVersion = XmlTag(r.body, "appversion");
    info.uniqueId = XmlTag(r.body, "uniqueid");
    info.state = XmlTag(r.body, "state");
    info.pairStatus = atoi(XmlTag(r.body, "PairStatus").c_str());
    info.serverCodecModeSupport = atoi(XmlTag(r.body, "ServerCodecModeSupport").c_str());
    info.runningGameId = atoi(XmlTag(r.body, "currentgame").c_str());
    int httpsPort = atoi(XmlTag(r.body, "HttpsPort").c_str());
    if (httpsPort > 0) {
        info.httpsPort = httpsPort;
    }
    int externalPort = atoi(XmlTag(r.body, "ExternalPort").c_str());
    if (externalPort > 0) {
        info.externalPort = externalPort;
    }
    return info;
}

std::vector<AppEntry> GetAppList(const std::string& host, std::string* errOut) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    std::vector<AppEntry> apps;
    if (!EnsureRng() || !EnsureClientCert(nullptr)) {
        if (errOut) *errOut = "cert";
        return apps;
    }
    HttpResult r = HttpGet(host, 47984, true, "applist", "", 8000);
    if (r.status != 200) {
        if (errOut) *errOut = r.error.empty() ? ("http_" + std::to_string(r.status)) : r.error;
        return apps;
    }

    size_t pos = 0;
    while (true) {
        size_t appStart = r.body.find("<App>", pos);
        if (appStart == std::string::npos) {
            break;
        }
        size_t appEnd = r.body.find("</App>", appStart);
        if (appEnd == std::string::npos) {
            break;
        }
        std::string block = r.body.substr(appStart, appEnd - appStart);
        AppEntry app;
        app.id = atoi(XmlTag(block, "ID").c_str());
        app.title = XmlTag(block, "AppTitle");
        app.hdrSupported = XmlTag(block, "IsHdrSupported") == "1";
        if (app.id != 0) {
            mdiag::Log("nvhttp", "app id=%d title=%s", app.id, app.title.c_str());
            apps.push_back(app);
        }
        pos = appEnd + 6;
    }
    return apps;
}

std::string PairBegin(const std::string& host, int timeoutMs) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    if (!EnsureRng() || !EnsureClientCert(nullptr)) {
        return "FAILED:cert";
    }

    HostInfo info = GetServerInfo(host, timeoutMs);
    if (!info.online) {
        return "FAILED:" + info.error;
    }
    int major = atoi(info.appVersion.c_str());
    bool sha256 = major >= 7;
    mdiag::Log("pair", "host=%s appversion=%s pairStatus=%d sha256=%d",
               host.c_str(), info.appVersion.c_str(), info.pairStatus, sha256);

    if (g_pair.serverCrtValid) {
        mbedtls_x509_crt_free(&g_pair.serverCrt);
        g_pair.serverCrtValid = false;
    }
    mbedtls_x509_crt_init(&g_pair.serverCrt);
    g_pair.active = false;
    g_pair.host = host;
    g_pair.useSha256 = sha256;
    g_pair.uniqueId = RandomUuidHex();

    RandomBytes(g_pair.salt, sizeof(g_pair.salt));

    std::string pemHex;
    std::string certPath = g_dataDir + "/client_v2.crt";
    if (!PemHex(certPath, &pemHex)) {
        return "FAILED:read_cert";
    }

    std::string query = "devicename=roth&updateState=1&phrase=getservercert&salt=" +
                        Hex(g_pair.salt, sizeof(g_pair.salt)) + "&clientcert=" + pemHex;
    HttpResult r = HttpGet(host, 47989, false, "pair", query, 120000, g_pair.uniqueId);
    if (r.status != 200) {
        return "FAILED:http_" + std::to_string(r.status);
    }
    if (XmlTag(r.body, "paired") != "1") {
        return "FAILED:paired0";
    }
    std::string plainCertHex = XmlTag(r.body, "plaincert");
    if (plainCertHex.empty()) {
        return "IN_PROGRESS";
    }
    std::vector<unsigned char> der;
    if (!Unhex(plainCertHex, der)) {
        return "FAILED:bad_cert_hex";
    }
    mdiag::Log("pair", "plaincert decoded=%zu bytes head=%02X%02X%02X%02X",
               der.size(), der.size() > 0 ? der[0] : 0, der.size() > 1 ? der[1] : 0,
               der.size() > 2 ? der[2] : 0, der.size() > 3 ? der[3] : 0);
    int parseRet = mbedtls_x509_crt_parse(&g_pair.serverCrt, der.data(), der.size());
    if (parseRet != 0) {
        // Some servers return the PEM text itself; retry as a NUL-terminated PEM buffer.
        std::string pem(der.begin(), der.end());
        if (pem.find("-----BEGIN") != std::string::npos) {
            pem.push_back('\0');
            mbedtls_x509_crt_free(&g_pair.serverCrt);
            mbedtls_x509_crt_init(&g_pair.serverCrt);
            parseRet = mbedtls_x509_crt_parse(&g_pair.serverCrt, 
                    reinterpret_cast<const unsigned char*>(pem.data()), pem.size());
            mdiag::Log("pair", "retried PEM parse ret=%d", parseRet);
        }
    }
    if (parseRet != 0) {
        return "FAILED:bad_server_cert_" + std::to_string(parseRet);
    }
    g_pair.serverCrtValid = true;

    FILE* f = fopen((g_dataDir + "/server.crt").c_str(), "w");
    if (f != nullptr) {
        fwrite(der.data(), 1, der.size(), f);
        fclose(f);
    }

    g_pair.active = true;
    mdiag::Log("pair", "server certificate received, waiting for PIN");
    return "READY";
}

std::string PairComplete(const std::string& host, const std::string& pin) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    if (!g_pair.active || g_pair.host != host || !g_pair.serverCrtValid || !EnsureRng()) {
        return "FAILED:no_session";
    }

    // aesKey = hash(salt || pin), truncated to 16 bytes
    std::vector<unsigned char> salted(g_pair.salt, g_pair.salt + sizeof(g_pair.salt));
    salted.insert(salted.end(), pin.begin(), pin.end());
    unsigned char hash[32];
    size_t hashLen = 0;
    HashData(g_pair.useSha256, salted.data(), salted.size(), hash, &hashLen);
    memcpy(g_pair.aesKey, hash, sizeof(g_pair.aesKey));

    // clientchallenge
    RandomBytes(g_pair.randomChallenge, sizeof(g_pair.randomChallenge));
    std::vector<unsigned char> challenge(g_pair.randomChallenge,
                                         g_pair.randomChallenge + sizeof(g_pair.randomChallenge));
    std::vector<unsigned char> encryptedChallenge = AesEcb(true, g_pair.aesKey, challenge);

    HttpResult r = HttpGet(host, 47989, false, "pair",
                           "devicename=roth&updateState=1&phrase=clientchallenge&clientchallenge=" +
                           Hex(encryptedChallenge.data(), encryptedChallenge.size()), 8000, g_pair.uniqueId);
    if (r.status != 200 || XmlTag(r.body, "paired") != "1") {
        return "FAILED:challenge";
    }

    std::vector<unsigned char> encResp;
    if (!Unhex(XmlTag(r.body, "challengeresponse"), encResp)) {
        return "FAILED:challengeresponse";
    }
    std::vector<unsigned char> decResp = AesEcb(false, g_pair.aesKey, encResp);
    size_t expectedHashLen = g_pair.useSha256 ? 32 : 20;
    if (decResp.size() < expectedHashLen + 16) {
        return "FAILED:short_response";
    }
    std::vector<unsigned char> serverResponse(decResp.begin(), decResp.begin() + expectedHashLen);
    std::vector<unsigned char> serverChallenge(decResp.begin() + expectedHashLen,
                                               decResp.begin() + expectedHashLen + 16);

    // serverchallengeresp
    unsigned char clientSecret[16];
    RandomBytes(clientSecret, sizeof(clientSecret));
    std::vector<unsigned char> respHashInput;
    respHashInput.insert(respHashInput.end(), serverChallenge.begin(), serverChallenge.end());
    respHashInput.insert(respHashInput.end(), g_clientCrt.sig.p,
                         g_clientCrt.sig.p + g_clientCrt.sig.len);
    respHashInput.insert(respHashInput.end(), clientSecret, clientSecret + sizeof(clientSecret));
    unsigned char respHash[32];
    size_t respHashLen = 0;
    HashData(g_pair.useSha256, respHashInput.data(), respHashInput.size(), respHash, &respHashLen);
    std::vector<unsigned char> respHashVec(respHash, respHash + respHashLen);
    std::vector<unsigned char> encryptedResp = AesEcb(true, g_pair.aesKey, respHashVec);

    r = HttpGet(host, 47989, false, "pair",
                "devicename=roth&updateState=1&phrase=serverchallengeresp&serverchallengeresp=" +
                Hex(encryptedResp.data(), encryptedResp.size()), 8000, g_pair.uniqueId);
    if (r.status != 200 || XmlTag(r.body, "paired") != "1") {
        return "FAILED:serverchallengeresp";
    }

    std::vector<unsigned char> pairingSecret;
    if (!Unhex(XmlTag(r.body, "pairingsecret"), pairingSecret) || pairingSecret.size() < 17) {
        return "FAILED:pairingsecret";
    }
    std::vector<unsigned char> serverSecret(pairingSecret.begin(), pairingSecret.begin() + 16);
    std::vector<unsigned char> serverSig(pairingSecret.begin() + 16, pairingSecret.end());

    // Authenticity of the server secret
    if (!VerifySha256(&g_pair.serverCrt.pk, serverSecret.data(), serverSecret.size(),
                      serverSig.data(), serverSig.size())) {
        mdiag::Log("pair", "server secret signature verification failed");
        return "FAILED:server_signature";
    }

    // Verify the PIN by checking the server's challenge response
    std::vector<unsigned char> verifyInput(g_pair.randomChallenge,
                                           g_pair.randomChallenge + sizeof(g_pair.randomChallenge));
    verifyInput.insert(verifyInput.end(), g_pair.serverCrt.sig.p,
                       g_pair.serverCrt.sig.p + g_pair.serverCrt.sig.len);
    verifyInput.insert(verifyInput.end(), serverSecret.begin(), serverSecret.end());
    unsigned char expected[32];
    size_t expectedLen = 0;
    HashData(g_pair.useSha256, verifyInput.data(), verifyInput.size(), expected, &expectedLen);
    if (serverResponse.size() != expectedLen || memcmp(serverResponse.data(), expected, expectedLen) != 0) {
        mdiag::Log("pair", "PIN verification failed");
        HttpGet(host, 47989, false, "unpair", "", 5000);
        g_pair.active = false;
        return "PIN_WRONG";
    }

    // clientpairingsecret
    std::vector<unsigned char> clientSecretVec(clientSecret, clientSecret + sizeof(clientSecret));
    std::vector<unsigned char> signedSecret = SignSha256(clientSecretVec);
    if (signedSecret.empty()) {
        return "FAILED:sign";
    }
    std::vector<unsigned char> clientPairingSecret = clientSecretVec;
    clientPairingSecret.insert(clientPairingSecret.end(), signedSecret.begin(), signedSecret.end());

    r = HttpGet(host, 47989, false, "pair",
                "devicename=roth&updateState=1&phrase=clientpairingsecret&clientpairingsecret=" +
                Hex(clientPairingSecret.data(), clientPairingSecret.size()), 8000, g_pair.uniqueId);
    if (r.status != 200 || XmlTag(r.body, "paired") != "1") {
        return "FAILED:clientpairingsecret";
    }

    // Final challenge over HTTPS (uses the client certificate)
    r = HttpGet(host, 47984, true, "pair", "devicename=roth&updateState=1&phrase=pairchallenge", 8000,
                g_pair.uniqueId);
    if (r.status != 200 || XmlTag(r.body, "paired") != "1") {
        return "FAILED:pairchallenge";
    }

    g_pair.active = false;
    mdiag::Log("pair", "paired successfully with %s", host.c_str());
    return "PAIRED";
}

LaunchResult LaunchApp(const std::string& host, int appId, int width, int height, int fps,
                       int bitrate, const std::string& riKeyHex, int riKeyId, bool virtualDisplay,
                       int audioConfiguration, bool sops, bool hostAudio) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    LaunchResult result;
    if (!EnsureRng() || !EnsureClientCert(nullptr)) {
        result.error = "cert";
        return result;
    }
    if (riKeyHex.size() != 32) {
        result.error = "bad_rikey";
        return result;
    }

    const int surroundAudioInfo = (((audioConfiguration >> 16) & 0xFFFF) << 16) |
                                  ((audioConfiguration >> 8) & 0xFF);
    char query[1024];
    snprintf(query, sizeof(query),
             "appid=%d&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%s&rikeyid=%d"
             "&localAudioPlayMode=%d&surroundAudioInfo=%d&remoteControllersBitmap=1&gcmap=1&gcpersist=1%s",
             appId, width, height, fps, sops ? 1 : 0, riKeyHex.c_str(), riKeyId,
             hostAudio ? 1 : 0, surroundAudioInfo,
             virtualDisplay ? "&virtualDisplay=1" : "");

    HttpResult r = HttpGet(host, 47984, true, "launch", query, 30000);
    if (r.status != 200 && r.error == "empty_response") {
        // The host may still be tearing down the previous session.
        std::this_thread::sleep_for(std::chrono::milliseconds(800));
        r = HttpGet(host, 47984, true, "launch", query, 30000);
    }
    if (r.status != 200) {
        result.error = r.error.empty() ? ("http_" + std::to_string(r.status)) : r.error;
        return result;
    }
    std::string gameSession = XmlTag(r.body, "gamesession");
    if (gameSession.empty() || gameSession == "0") {
        result.error = "gamesession0";
        return result;
    }
    result.ok = true;
    result.sessionUrl = XmlTag(r.body, "sessionUrl0");
    mdiag::Log("nvhttp", "launch ok appid=%d sessionUrl=%s", appId, result.sessionUrl.c_str());
    return result;
}

bool GetBoxArt(const std::string& host, int appId, std::string* outBytes, std::string* errOut) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    if (!EnsureRng() || !EnsureClientCert(nullptr)) {
        if (errOut) *errOut = "cert";
        return false;
    }
    std::string query = "appid=" + std::to_string(appId) + "&AssetType=2&AssetIdx=0";
    HttpResult r = HttpGet(host, 47984, true, "appasset", query, 10000);
    if (r.status != 200 || r.body.empty()) {
        if (errOut) *errOut = r.error.empty() ? ("http_" + std::to_string(r.status)) : r.error;
        return false;
    }
    *outBytes = std::move(r.body);
    return true;
}

bool QuitApp(const std::string& host) {
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    HttpResult r = HttpGet(host, 47984, true, "cancel", "", 8000);
    return r.status == 200 && XmlTag(r.body, "cancel") == "1";
}

} // namespace nvhttp
