#ifndef MOONLIGHT_OHOS_VIDEODEC_H
#define MOONLIGHT_OHOS_VIDEODEC_H

#include "Limelight.h"

#include <string>

namespace videodec {

void SetSurfaceId(const std::string& surfaceId);
bool Setup(int videoFormat, int width, int height, int fps);
bool Submit(PDECODE_UNIT du);
void Start();
void SetFullRange(bool full);
void Stop();
void Cleanup();
bool IsReady();

} // namespace videodec

#endif
