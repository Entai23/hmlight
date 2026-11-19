#ifndef MOONLIGHT_OHOS_DIAG_H
#define MOONLIGHT_OHOS_DIAG_H

#include <cstdint>
#include <string>

namespace mdiag {

void SetLogDir(const std::string& dir);
void SetEnabled(bool on);
void Log(const char* category, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void EventJson(const char* category, const std::string& jsonFields);
std::string JsonEscape(const std::string& in);
uint64_t NowUs();
std::string LogFilePath();

} // namespace mdiag

#endif
