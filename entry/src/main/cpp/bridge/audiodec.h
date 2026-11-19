#ifndef MOONLIGHT_OHOS_AUDIODEC_H
#define MOONLIGHT_OHOS_AUDIODEC_H

#include "Limelight.h"

namespace audiodec {

bool Init(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, int flags);
void Start();
void Stop();
void Cleanup();
void DecodeAndPlaySample(char* sampleData, int sampleLength);

} // namespace audiodec

#endif
