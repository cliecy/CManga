#ifndef VENERA_APPLE_METAL_PROVIDER_H_
#define VENERA_APPLE_METAL_PROVIDER_H_

#include <string>
#include <onnxruntime_c_api.h>

namespace image_ai {

// An OrtEnv must already exist. Availability creates a real Dawn/Metal device;
// it does not claim that a particular model has complete GPU kernel coverage.
bool AppleMetalAvailable(std::string* reason = nullptr);
void AppendAppleMetalProvider(const OrtApi* api, OrtSessionOptions* options);
std::string AppleMetalDeviceName();

}  // namespace image_ai
#endif
