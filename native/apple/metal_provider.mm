#include "metal_provider.h"
#include "../image_ai/engine.h"

#include <array>
#include <cstring>
#include <memory>

// Only the pinned, patched Apple framework exports this attestation. A generic
// CPU-only ORT binary must not be mistaken for WebGPU because its headers match.
extern "C" int VeneraOrtMetalStatus(char*, size_t, char*, size_t)
    __attribute__((weak_import));

namespace image_ai {
namespace {

void Check(const OrtApi* api, OrtStatus* status) {
  if (!status) return;
  std::string message = api->GetErrorMessage(status);
  api->ReleaseStatus(status);
  throw Error("backend_unavailable", "Metal GPU unavailable: " + message);
}

const OrtApi* MetalApi() {
  const OrtApiBase* base = OrtGetApiBase();
  const OrtApi* api = base ? base->GetApi(ORT_API_VERSION) : nullptr;
  if (!api || !VeneraOrtMetalStatus) {
    throw Error("backend_unavailable", "The native ONNX Runtime Metal dependency is missing or incompatible.");
  }
  if (std::strcmp(base->GetVersionString(), "1.29.0") != 0) {
    throw Error("backend_unavailable", "The native Metal runtime version does not match the pinned Apple dependency.");
  }
  return api;
}

std::string DeviceName() {
  std::array<char, 1024> name{};
  std::array<char, 2048> reason{};
  if (!VeneraOrtMetalStatus ||
      !VeneraOrtMetalStatus(name.data(), name.size(), reason.data(), reason.size())) {
    throw Error("backend_unavailable", reason[0] ? reason.data() : "No hardware Metal adapter is available.");
  }
  return name.data();
}

void Append(const OrtApi* api, OrtSessionOptions* options) {
  Check(api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"));
  Check(api, api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
  // Exact v1.29 native provider options. Metal is enforced inside the pinned
  // runtime: upstream dawnBackendType only accepts D3D12/Vulkan, not "Metal".
  const char* keys[] = {"preserveDevice", "validationMode", "storageBufferCacheMode"};
  const char* values[] = {"1", "full", "disabled"};
  Check(api, api->SessionOptionsAppendExecutionProvider(options, "WebGPU", keys, values, 3));
  DeviceName();
}

}  // namespace

bool AppleMetalAvailable(std::string* reason) {
  try {
    const OrtApi* api = MetalApi();
    // Keep the real context alive alongside ORT's environment, rather than
    // repeatedly creating and destroying a GPU just to paint capabilities.
    static const auto probe_options = [api] {
      OrtSessionOptions* options = nullptr;
      Check(api, api->CreateSessionOptions(&options));
      std::unique_ptr<OrtSessionOptions, decltype(api->ReleaseSessionOptions)> owner(
          options, api->ReleaseSessionOptions);
      Append(api, options);
      return owner;
    }();
    DeviceName();  // Report device loss even after a successful initial probe.
    if (reason) reason->clear();
    return true;
  } catch (const std::exception& error) {
    if (reason) *reason = error.what();
    return false;
  }
}

void AppendAppleMetalProvider(const OrtApi* api, OrtSessionOptions* options) {
  if (api != MetalApi() || !options) {
    throw Error("backend_unavailable", "Invalid native Metal runtime session options.");
  }
  Append(api, options);
}

std::string AppleMetalDeviceName() {
  MetalApi();
  return DeviceName();
}

}  // namespace image_ai
