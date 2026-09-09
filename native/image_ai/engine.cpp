#include "engine.h"
#include "image_memory.h"

#include <onnxruntime_c_api.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <list>
#include <mutex>
#include <sstream>
#include <utility>

#ifdef __APPLE__
#include <TargetConditionals.h>
#include "../apple/metal_provider.h"
#if TARGET_OS_IOS
#include <os/proc.h>
#endif
#endif

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dml_provider_factory.h>
#endif

namespace image_ai {
namespace {
#if defined(__APPLE__) && TARGET_OS_IOS
// Bound image working sets separately from model weights on mobile devices.
constexpr size_t kCacheBytes = 24u * 1024u * 1024u;
constexpr size_t kMaxSessions = 1;
#else
constexpr size_t kCacheBytes = 128u * 1024u * 1024u;
constexpr size_t kMaxSessions = 2;
#endif
constexpr int kTile = 256;
constexpr int kOverlap = 24;

bool IsNewColor(const std::string& type) {
  return type == "manga_v2" || type == "manga_light" || type == "ddcolor" || type == "anime_deoldify";
}

void CheckType(const std::string& type) {
  if (type != "esrgan" && type != "deoldify" && !IsNewColor(type)) {
    throw Error("unsupported_type", "Supported types: esrgan, deoldify, manga_v2, manga_light, ddcolor, anime_deoldify.");
  }
}

void Check(const OrtApi* api, OrtStatus* status) {
  if (!status) return;
  std::string message = api->GetErrorMessage(status);
  api->ReleaseStatus(status);
  throw Error("inference_failed", message);
}

template <typename T> struct OrtOwner {
  T* ptr = nullptr;
  void(ORT_API_CALL* release)(T*) = nullptr;
  OrtOwner(T* value, void(ORT_API_CALL* deleter)(T*)) : ptr(value), release(deleter) {}
  ~OrtOwner() { if (ptr) release(ptr); }
  OrtOwner(const OrtOwner&) = delete;
  OrtOwner& operator=(const OrtOwner&) = delete;
};

void Pixels(int64_t width, int64_t height) {
  ValidateImageDimensions(width, height);
}

std::filesystem::path Path(const std::string& text) {
  return std::filesystem::u8path(text);
}

std::string FileIdentity(const std::string& name) {
  std::error_code error;
  const auto path = Path(name);
  const auto size = std::filesystem::file_size(path, error);
  if (error) throw Error("model_unavailable", "Cannot read model: " + name + ": " + error.message());
  const auto modified = std::filesystem::last_write_time(path, error);
  if (error) throw Error("model_unavailable", "Cannot inspect model: " + error.message());
  // libc++ uses a 128-bit file-clock count, which std::to_string cannot accept.
  // Split it without discarding subsecond changes or narrowing the full epoch.
  const auto ticks = modified.time_since_epoch();
  const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(ticks);
  const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(ticks - seconds);
  return name + ":" + std::to_string(size) + ":" + std::to_string(seconds.count()) +
      ":" + std::to_string(nanos.count());
}

struct Runtime {
  const OrtApi* api = nullptr;
  OrtEnv* env = nullptr;
#ifdef _WIN32
  HMODULE module = nullptr;
  const OrtDmlApi* dml = nullptr;
#endif
  explicit Runtime(bool directml) {
    try {
      if (directml) {
#ifdef _WIN32
        std::wstring exe(32768, L'\0');
        const DWORD size = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
        if (!size || size >= exe.size()) throw Error("backend_unavailable", "Cannot locate executable directory.");
        exe.resize(size);
        const auto dll = std::filesystem::path(exe).parent_path() / L"image_ai" / L"directml" / L"onnxruntime.dll";
        module = LoadLibraryExW(dll.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) throw Error("backend_unavailable", "DirectML runtime could not load (Windows error " + std::to_string(GetLastError()) + "); using CPU.");
        using GetApi = const OrtApiBase*(ORT_API_CALL*)();
        const auto get_api = reinterpret_cast<GetApi>(GetProcAddress(module, "OrtGetApiBase"));
        if (!get_api) throw Error("backend_unavailable", "DirectML runtime has no OrtGetApiBase export.");
        api = get_api()->GetApi(ORT_API_VERSION);
        if (!api) throw Error("backend_unavailable", "DirectML runtime API version does not match this application.");
        Check(api, api->GetExecutionProviderApi("DML", ORT_API_VERSION, reinterpret_cast<const void**>(&dml)));
#else
        throw Error("backend_unavailable", "DirectML is only available on Windows; using CPU.");
#endif
      } else {
#ifdef _WIN32
        std::wstring exe(32768, L'\0');
        const DWORD size = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
        if (!size || size >= exe.size()) throw Error("backend_unavailable", "Cannot locate executable directory.");
        exe.resize(size);
        const auto dll = std::filesystem::path(exe).parent_path() / L"onnxruntime.dll";
        module = LoadLibraryExW(dll.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) throw Error("backend_unavailable", "CPU ONNX Runtime could not load (Windows error " + std::to_string(GetLastError()) + ").");
        using GetApi = const OrtApiBase*(ORT_API_CALL*)();
        const auto get_api = reinterpret_cast<GetApi>(GetProcAddress(module, "OrtGetApiBase"));
        if (!get_api) throw Error("backend_unavailable", "CPU runtime has no OrtGetApiBase export.");
        api = get_api()->GetApi(ORT_API_VERSION);
#else
        api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
#endif
        if (!api) throw Error("backend_unavailable", "ONNX Runtime API version does not match this application.");
      }
      Check(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "venera_image_ai", &env));
    } catch (...) {
      Close();
      throw;
    }
  }
  void Close() noexcept {
    if (env) { api->ReleaseEnv(env); env = nullptr; }
#ifdef _WIN32
    if (module) { FreeLibrary(module); module = nullptr; }
#endif
  }
  ~Runtime() { Close(); }
};

struct Session {
  Runtime& runtime;
  OrtSession* session = nullptr;
  struct Input {
    std::string name;
    std::vector<int64_t> shape;
    std::vector<float> zeros;
  };
  std::vector<Input> inputs;
  std::vector<float> input_buffer;
  int output_channels = 0;
  std::string output_name;
  ModelInfo info;
  std::array<int64_t, 4> output_shape{};
  std::string identity;
  std::string path;
  std::string type;
  std::string backend;
  bool validated = false;

  Session(Runtime& rt, const std::string& file, const std::string& kind,
          const std::string& key, bool directml)
      : runtime(rt), identity(key), path(file), type(kind), backend(directml ? "directml" : "cpu") {
    auto api = runtime.api;
    OrtOwner<OrtSessionOptions> options(nullptr, api->ReleaseSessionOptions);
    Check(api, api->CreateSessionOptions(&options.ptr));
#ifdef __APPLE__
    backend = "metal";
    AppendAppleMetalProvider(api, options.ptr);
#endif
    Check(api, api->SetSessionGraphOptimizationLevel(options.ptr, ORT_ENABLE_ALL));
#if defined(__APPLE__) && TARGET_OS_IOS
    Check(api, api->SetIntraOpNumThreads(options.ptr, 2));
    Check(api, api->DisableCpuMemArena(options.ptr));
    Check(api, api->DisableMemPattern(options.ptr));
#if !TARGET_OS_SIMULATOR
    // Simulator processes have no iOS jetsam headroom; the API returns zero.
    const auto available = os_proc_available_memory();
    const auto model_bytes = std::filesystem::file_size(Path(file));
    if (model_bytes > available || available - model_bytes < 128u * 1024u * 1024u) {
      throw Error("memory_limit", "Insufficient iOS memory headroom to load this model; choose a smaller model or close other work.");
    }
#endif
#else
    Check(api, api->SetIntraOpNumThreads(options.ptr, 4));
#endif
    if (directml) {
      Check(api, api->DisableMemPattern(options.ptr));
      Check(api, api->SetSessionExecutionMode(options.ptr, ORT_SEQUENTIAL));
      // Never report DirectML when ORT silently assigned the model to CPU.
      Check(api, api->AddSessionConfigEntry(options.ptr, "session.disable_cpu_ep_fallback", "1"));
#ifdef _WIN32
      Check(api, runtime.dml->SessionOptionsAppendExecutionProvider_DML(options.ptr, 0));
#endif
    }
    OrtOwner<OrtSession> created(nullptr, api->ReleaseSession);
    Check(api, api->CreateSession(runtime.env, Path(file).c_str(), options.ptr, &created.ptr));
    size_t input_count = 0, output_count = 0;
    Check(api, api->SessionGetInputCount(created.ptr, &input_count));
    Check(api, api->SessionGetOutputCount(created.ptr, &output_count));
    const bool light = kind == "manga_light";
    if (input_count != (light ? 4u : 1u) || output_count != 1) {
      throw Error("incompatible_model", kind + (light
          ? " requires four generator inputs and one RGB output (no SAM encoder)."
          : " requires exactly one image input and one image output."));
    }
    OrtAllocator* allocator = nullptr;
    Check(api, api->GetAllocatorWithDefaultOptions(&allocator));
    auto name = [&](bool input, size_t index) {
      char* value = nullptr;
      Check(api, input ? api->SessionGetInputName(created.ptr, index, allocator, &value)
                       : api->SessionGetOutputName(created.ptr, index, allocator, &value));
      std::string result(value);
      allocator->Free(allocator, value);
      return result;
    };
    auto shape = [&](bool input, size_t index, const std::string& tensor_name) {
      OrtOwner<OrtTypeInfo> type_info(nullptr, api->ReleaseTypeInfo);
      Check(api, input ? api->SessionGetInputTypeInfo(created.ptr, index, &type_info.ptr)
                       : api->SessionGetOutputTypeInfo(created.ptr, index, &type_info.ptr));
      const OrtTensorTypeAndShapeInfo* tensor = nullptr;
      Check(api, api->CastTypeInfoToTensorInfo(type_info.ptr, &tensor));
      if (!tensor) throw Error("incompatible_model", kind + ": " + tensor_name + " must be a tensor.");
      ONNXTensorElementDataType element;
      Check(api, api->GetTensorElementType(tensor, &element));
      if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        throw Error("incompatible_model", kind + ": " + tensor_name +
            " must have float32 I/O; internal FP16/int8 weights do not imply half/quantized image I/O.");
      }
      size_t rank = 0;
      Check(api, api->GetDimensionsCount(tensor, &rank));
      const size_t expected_rank = light && input && tensor_name == "wd14_embedding" ? 2 : 4;
      if (rank != expected_rank) throw Error("incompatible_model", kind + ": " + tensor_name +
          (expected_rank == 2 ? " must be rank-two [1,1024]." : " must be rank-four NCHW."));
      std::vector<int64_t> dims(rank);
      Check(api, api->GetDimensions(tensor, dims.data(), dims.size()));
      if (dims[0] > 1 || std::find(dims.begin(), dims.end(), 0) != dims.end()) {
        throw Error("incompatible_model", kind + ": " + tensor_name + " must support batch one with nonzero dimensions.");
      }
      return dims;
    };
    for (size_t i = 0; i < input_count; ++i) {
      Input input;
      input.name = name(true, i);
      input.shape = shape(true, i, input.name);
      this->inputs.push_back(std::move(input));
    }
    output_name = name(false, 0);
    const auto output = shape(false, 0, output_name);
    std::copy(output.begin(), output.end(), output_shape.begin());
    if (IsNewColor(kind)) {
      const char* expected_input = light ? "L_bw" : "input";
      const char* expected_output = light ? "rgb_pred" : kind == "manga_v2" ? "rgb" : "output";
      auto main = std::find_if(this->inputs.begin(), this->inputs.end(),
          [&](const Input& input) { return input.name == expected_input; });
      if (main == this->inputs.end() || output_name != expected_output) {
        throw Error("incompatible_model", kind + ": expected main input " + expected_input + " and output " + expected_output + ".");
      }
      std::iter_swap(this->inputs.begin(), main);
    }
    const auto& input = this->inputs.front().shape;
    const int expected_channels = kind == "manga_v2" ? 5 : light ? 1 : 3;
    output_channels = kind == "ddcolor" ? 2 : kind == "esrgan" ? static_cast<int>(input[1]) : 3;
    if ((kind == "esrgan" ? input[1] != 1 && input[1] != 3 : input[1] != expected_channels) ||
        (IsNewColor(kind) ? output_shape[1] != output_channels
                          : output_shape[1] > 0 && output_shape[1] != output_channels)) {
      throw Error("incompatible_model", kind + ": incompatible NCHW input/output channels; expected " +
          (kind == "esrgan" ? std::string("matching 1 or 3") :
           std::to_string(expected_channels) + " input and " + std::to_string(output_channels) + " output") + ".");
    }
    info.channels = static_cast<int>(input[1]);
    if (input[2] > 2048 || input[3] > 2048) throw Error("incompatible_model", "Fixed model input exceeds the supported 2048-pixel side.");
    info.input_height = input[2] > 0 ? static_cast<int>(input[2]) : 0;
    info.input_width = input[3] > 0 ? static_cast<int>(input[3]) : 0;
    if (kind == "manga_v2" || light) {
      for (size_t axis = 2; axis < 4; ++axis) {
        if ((input[axis] > 0 && input[axis] != 512) ||
            (output_shape[axis] > 0 && output_shape[axis] != 512)) {
          throw Error("incompatible_model", kind + ": fixed image axes must be 512 for the supported inference policy.");
        }
      }
    } else if (kind == "ddcolor") {
      if (info.input_height != info.input_width || (info.input_width && info.input_width % 32)) {
        throw Error("incompatible_model", "ddcolor requires dynamic spatial axes or a fixed square side divisible by 32.");
      }
      const int side = info.input_width ? info.input_width : 256;
      for (size_t axis = 2; axis < 4; ++axis) {
        if (output_shape[axis] > 0 && output_shape[axis] != side) {
          throw Error("incompatible_model", "ddcolor fixed output dimensions must match the selected input side.");
        }
      }
    } else if (kind == "anime_deoldify") {
      const std::array<int64_t, 4> expected{1, 3, 256, 256};
      if (!std::equal(input.begin(), input.end(), expected.begin()) || output_shape != expected) {
        throw Error("incompatible_model", "anime_deoldify requires fixed float32 input/output [1,3,256,256].");
      }
    }
    if (light) {
      static constexpr const char* names[] = {"sam_level0", "sam_level1", "wd14_embedding"};
      const std::array<std::vector<int64_t>, 3> shapes{
          std::vector<int64_t>{1, 256, 32, 32}, {1, 256, 16, 16}, {1, 1024}};
      for (size_t i = 0; i < 3; ++i) {
        auto found = std::find_if(this->inputs.begin() + i + 1, this->inputs.end(),
            [&](const Input& value) { return value.name == names[i]; });
        if (found == this->inputs.end()) throw Error("incompatible_model", std::string("manga_light requires input ") + names[i] + ".");
        std::iter_swap(this->inputs.begin() + i + 1, found);
        auto& auxiliary = this->inputs[i + 1];
        size_t count = 1;
        for (size_t axis = 0; axis < shapes[i].size(); ++axis) {
          if (auxiliary.shape[axis] > 0 && auxiliary.shape[axis] != shapes[i][axis]) {
            throw Error("incompatible_model", "manga_light: " + auxiliary.name + " shape is incompatible with 512px zero-semantic mode.");
          }
          count *= static_cast<size_t>(shapes[i][axis]);
        }
        auxiliary.shape = shapes[i];
        auxiliary.zeros.resize(count, 0.0f);
      }
    }
    // New color contracts are fully specified by graph metadata. Do not run a
    // throwaway prediction at inspection time (especially for zero intensity).
    if (IsNewColor(kind)) validated = true;
    if (kind == "esrgan" && info.input_width && info.input_height &&
        output_shape[2] > 0 && output_shape[3] > 0) {
      SetScale(info.input_width, info.input_height, output_shape[3], output_shape[2]);
      validated = true;
    }
    session = created.ptr;
    created.ptr = nullptr;
  }
  ~Session() { if (session) runtime.api->ReleaseSession(session); }
  void SetScale(int width, int height, int64_t out_width, int64_t out_height) {
    if (out_width % width || out_height % height || out_width / width != out_height / height ||
        out_width / width < 1 || out_width / width > 8) {
      throw Error("incompatible_model", "SR output must preserve aspect ratio with an integer native scale from 1 to 8.");
    }
    info.scale = static_cast<int>(out_width / width);
  }
};

struct Decoded {
  cv::Mat bgr;
  cv::Mat alpha;
};

Decoded Decode(const std::vector<uint8_t>& bytes) {
  const auto expected_pixels = ValidateEncodedImage(bytes.data(), bytes.size());
  cv::Mat image = cv::imdecode(bytes, cv::IMREAD_UNCHANGED);
  if (image.empty()) throw Error("invalid_image", "Image could not be decoded.");
  Pixels(image.cols, image.rows);
  if (image.total() > expected_pixels) {
    throw Error("invalid_image", "Decoded image is larger than its inspected header.");
  }
  if (image.depth() == CV_16U) image.convertTo(image, CV_8U, 1.0 / 257.0);
  if (image.depth() != CV_8U) throw Error("invalid_image", "Only 8-bit and 16-bit images are supported.");
  Decoded result;
  if (image.channels() == 4) {
    cv::extractChannel(image, result.alpha, 3);
    cv::cvtColor(image, result.bgr, cv::COLOR_BGRA2BGR);
  } else if (image.channels() == 3) {
    result.bgr = std::move(image);
  } else if (image.channels() == 1) {
    cv::cvtColor(image, result.bgr, cv::COLOR_GRAY2BGR);
  } else {
    throw Error("invalid_image", "Unsupported image channel count.");
  }
  return result;
}

float ToLinear(float value) {
  value = std::clamp(value, 0.0f, 1.0f);
  return value <= .04045f ? value / 12.92f : std::pow((value + .055f) / 1.055f, 2.4f);
}
float ToSrgb(float value) {
  value = std::clamp(value, 0.0f, 1.0f);
  return value <= .0031308f ? value * 12.92f : 1.055f * std::pow(value, 1.0f / 2.4f) - .055f;
}

// Resize linear-light premultiplied pixels, not hidden colors under transparent edges.
cv::Mat LinearResize(const cv::Mat& bgr, const cv::Mat& alpha, cv::Size size,
                     const cv::Mat& target_alpha) {
  cv::Mat linear(bgr.size(), CV_32FC3);
  for (int y = 0; y < bgr.rows; ++y) {
    const auto* src = bgr.ptr<cv::Vec3f>(y);
    const uint8_t* a = alpha.empty() ? nullptr : alpha.ptr<uint8_t>(y);
    auto* dst = linear.ptr<cv::Vec3f>(y);
    for (int x = 0; x < bgr.cols; ++x) {
      const float opacity = a ? a[x] / 255.0f : 1.0f;
      for (int c = 0; c < 3; ++c) dst[x][c] = ToLinear(src[x][c]) * opacity;
    }
  }
  const int interpolation = size.area() < bgr.size().area() ? cv::INTER_AREA : cv::INTER_CUBIC;
  if (linear.size() != size) cv::resize(linear, linear, size, 0, 0, interpolation);
  if (!alpha.empty()) {
    cv::Mat filtered_alpha;
    alpha.convertTo(filtered_alpha, CV_32F, 1.0 / 255.0);
    if (filtered_alpha.size() != size) cv::resize(filtered_alpha, filtered_alpha, size, 0, 0, interpolation);
    // Both branches must use exactly the same final opacity. Unpremultiply the
    // resampling filter's alpha before premultiplying the shared target alpha.
    for (int y = 0; y < linear.rows; ++y) {
      auto* pixels = linear.ptr<cv::Vec3f>(y);
      const auto* filtered = filtered_alpha.ptr<float>(y);
      const auto* final_alpha = target_alpha.ptr<uint8_t>(y);
      for (int x = 0; x < linear.cols; ++x) {
        const float opacity = final_alpha[x] / 255.0f;
        const float factor = filtered[x] > 1e-6f ? opacity / filtered[x] : 0;
        for (float& channel : pixels[x].val) {
          channel = std::clamp(channel * factor, 0.0f, opacity);
        }
      }
    }
  } else {
    // Cubic resampling can overshoot. Mix valid linear-light branch colors,
    // not values that differ from the clipped 0%/100% endpoint images.
    cv::max(linear, 0, linear);
    cv::min(linear, 1, linear);
  }
  return linear;
}

std::vector<uint8_t> Encode(const cv::Mat& bgr, const cv::Mat& alpha) {
  cv::Mat bytes;
  bgr.convertTo(bytes, CV_8U, 255.0);
  if (!alpha.empty()) {
    cv::cvtColor(bytes, bytes, cv::COLOR_BGR2BGRA);
    cv::insertChannel(alpha, bytes, 3);
  }
  std::vector<uint8_t> output;
  if (!cv::imencode(".png", bytes, output)) throw Error("encode_failed", "PNG encoding failed.");
  return output;
}

std::string KeyPart(const std::string& text) {
  return std::to_string(text.size()) + ":" + text;
}
}  // namespace

struct Engine::Impl {
  std::unique_ptr<Runtime> directml;
  std::string dml_error;
  bool dml_checked = false;
  std::atomic<bool> cancelled{false};
  std::mutex run_mutex;
  const OrtApi* active_api = nullptr;
  OrtRunOptions* active_run = nullptr;
  std::list<std::unique_ptr<Session>> sessions;
  struct Metadata {
    std::string identity;
    std::string path;
    ModelInfo info;
  };
  std::list<Metadata> metadata;
  struct Base {
    std::string key;
    std::string path;
    std::string backend;
    std::string reason;
    cv::Mat pixels;
    ModelInfo info;
    size_t Bytes() const { return pixels.total() * pixels.elemSize(); }
  };
  std::list<Base> cache;
  size_t cache_bytes = 0;
  uint64_t inference_runs = 0;

  void CheckCancelled() {
    if (cancelled.load()) throw Error("cancelled", "Image AI processing was cancelled.");
  }
  Runtime& DefaultRuntime() {
    // The Apple Metal context survives reader/background engine recreation.
    // Keep its ORT logger/environment alive for the same process lifetime.
    static Runtime runtime(false);
    return runtime;
  }
  Runtime& Dml() {
    if (!directml && !dml_checked) {
      dml_checked = true;
      try { directml = std::make_unique<Runtime>(true); }
      catch (const std::exception& error) { dml_error = error.what(); }
    }
    if (!directml) throw Error("backend_unavailable", dml_error);
    return *directml;
  }
  cv::Mat Run(Session& model, const cv::Mat& input) {
    CheckCancelled();
    const auto api = model.runtime.api;
    const int channels = model.info.channels;
    const int supplied_channels = input.channels();
    if (input.depth() != CV_32F ||
        supplied_channels != (model.type == "manga_v2" ? 1 : channels) ||
        (model.info.input_width && input.cols != model.info.input_width) ||
        (model.info.input_height && input.rows != model.info.input_height)) {
      throw Error("incompatible_model", model.type + ": prepared input does not match the graph's float32 NCHW shape.");
    }
    const size_t plane = input.total();
    // Include tensor staging/readback and a worst-case scale while probing a
    // dynamic legacy SR graph. Default tiles stay bounded independently of
    // the full image, including fixed-size imported models.
    const int scale = model.type == "esrgan"
        ? (model.validated ? model.info.scale : 8) : 1;
    Pixels(static_cast<int64_t>(input.cols) * scale,
           static_cast<int64_t>(input.rows) * scale);
    const uint64_t output_pixels = plane * scale * scale;
    ValidateImageWorkingSet(plane, output_pixels, output_pixels);
    float* input_data = nullptr;
    if (channels == 1 && input.isContinuous()) {
      // ORT reads this borrowed tensor synchronously; single-channel inputs
      // already have planar layout and need no extra image-sized copy.
      input_data = const_cast<float*>(input.ptr<float>());
    } else {
      auto& buffer = model.input_buffer;
      buffer.resize(plane * channels);
      if (model.type == "manga_v2") std::fill(buffer.begin() + plane, buffer.end(), 0.0f);
      for (int y = 0; y < input.rows; ++y) {
        const float* src = input.ptr<float>(y);
        for (int x = 0; x < input.cols; ++x) {
          for (int c = 0; c < supplied_channels; ++c) {
            buffer[c * plane + y * input.cols + x] = src[x * supplied_channels + c];
          }
        }
      }
      input_data = buffer.data();
    }
    const std::array<int64_t, 4> shape{1, channels, input.rows, input.cols};
    OrtOwner<OrtMemoryInfo> memory(nullptr, api->ReleaseMemoryInfo);
    Check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory.ptr));
    std::array<OrtOwner<OrtValue>, 4> tensors{{
        {nullptr, api->ReleaseValue}, {nullptr, api->ReleaseValue},
        {nullptr, api->ReleaseValue}, {nullptr, api->ReleaseValue}}};
    std::array<const char*, 4> input_names{};
    std::array<const OrtValue*, 4> input_values{};
    for (size_t i = 0; i < model.inputs.size(); ++i) {
      auto& spec = model.inputs[i];
      Check(api, api->CreateTensorWithDataAsOrtValue(memory.ptr,
          i == 0 ? input_data : spec.zeros.data(),
          (i == 0 ? plane * channels : spec.zeros.size()) * sizeof(float),
          i == 0 ? shape.data() : spec.shape.data(),
          i == 0 ? shape.size() : spec.shape.size(),
          ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensors[i].ptr));
      input_names[i] = spec.name.c_str();
      input_values[i] = tensors[i].ptr;
    }
    OrtOwner<OrtRunOptions> run(nullptr, api->ReleaseRunOptions);
    Check(api, api->CreateRunOptions(&run.ptr));
    const char* output_name = model.output_name.c_str();
    OrtOwner<OrtValue> output(nullptr, api->ReleaseValue);
    {
      std::lock_guard<std::mutex> lock(run_mutex);
      CheckCancelled();
      active_api = api;
      active_run = run.ptr;
    }
    OrtStatus* status = api->Run(model.session, run.ptr, input_names.data(), input_values.data(),
                                model.inputs.size(), &output_name, 1, &output.ptr);
    {
      std::lock_guard<std::mutex> lock(run_mutex);
      active_run = nullptr;
      active_api = nullptr;
    }
    ++inference_runs;
    Check(api, status);
    CheckCancelled();
    OrtOwner<OrtTensorTypeAndShapeInfo> dimensions(nullptr, api->ReleaseTensorTypeAndShapeInfo);
    Check(api, api->GetTensorTypeAndShape(output.ptr, &dimensions.ptr));
    size_t rank = 0;
    Check(api, api->GetDimensionsCount(dimensions.ptr, &rank));
    if (rank != 4) throw Error("incompatible_model", model.type + ": inference output is not NCHW.");
    ONNXTensorElementDataType element;
    Check(api, api->GetTensorElementType(dimensions.ptr, &element));
    if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      throw Error("incompatible_model", model.type + ": inference output must be float32.");
    }
    std::array<int64_t, 4> output_shape;
    Check(api, api->GetDimensions(dimensions.ptr, output_shape.data(), output_shape.size()));
    const int output_channels = model.output_channels;
    if (output_shape[0] != 1 || output_shape[1] != output_channels) {
      throw Error("incompatible_model", model.type + ": inference output batch/channel mismatch.");
    }
    Pixels(output_shape[3], output_shape[2]);
    if (IsNewColor(model.type) && (output_shape[2] != input.rows || output_shape[3] != input.cols)) {
      throw Error("incompatible_model", model.type + ": output spatial dimensions must match the prepared image input.");
    }
    float* data = nullptr;
    Check(api, api->GetTensorMutableData(output.ptr, reinterpret_cast<void**>(&data)));
    const int width = static_cast<int>(output_shape[3]);
    const int height = static_cast<int>(output_shape[2]);
    cv::Mat result(height, width, CV_MAKETYPE(CV_32F, output_channels));
    const size_t output_plane = result.total();
    for (int y = 0; y < height; ++y) {
      float* dst = result.ptr<float>(y);
      for (int x = 0; x < width; ++x) {
        for (int c = 0; c < output_channels; ++c) {
          const float value = data[c * output_plane + y * width + x];
          if (!std::isfinite(value)) throw Error("inference_failed", "Model produced non-finite pixels.");
          dst[x * output_channels + c] = value;
        }
      }
    }
    return result;
  }

  Session& GetSession(const std::string& path, const std::string& type,
                      const std::string& model_id, bool dml) {
    CheckType(type);
    const std::string file_identity = KeyPart(FileIdentity(path));
#ifdef __APPLE__
    const std::string suffix = KeyPart(type) + "metal";
#else
    const std::string suffix = KeyPart(type) + (dml ? "dml" : "cpu");
#endif
    const std::string metadata_identity = file_identity + KeyPart(type);
    const std::string identity = file_identity + KeyPart(model_id) + suffix;
    const std::string inspected_identity = file_identity + KeyPart("") + suffix;
    for (auto it = sessions.begin(); it != sessions.end(); ++it) {
      if ((*it)->identity == identity || (!model_id.empty() && (*it)->identity == inspected_identity)) {
        (*it)->identity = identity;
        sessions.splice(sessions.begin(), sessions, it);
        return *sessions.front();
      }
    }
    // Release before opening another large model, not after its peak allocation.
    while (sessions.size() >= kMaxSessions) sessions.pop_back();
    auto session = std::make_unique<Session>(dml ? Dml() : DefaultRuntime(), path, type, identity, dml);
    for (const auto& entry : metadata) {
      if (entry.identity == metadata_identity) {
        session->info = entry.info;
        session->validated = true;
        break;
      }
    }
    if (!session->validated) {
      const int default_side = type == "deoldify" ? 256 : 64;
      const int width = session->info.input_width ? session->info.input_width : default_side;
      const int height = session->info.input_height ? session->info.input_height : default_side;
      cv::Mat probe(height, width, CV_MAKETYPE(CV_32F, session->info.channels), cv::Scalar::all(type == "deoldify" ? 127.5 : .5));
      cv::Mat output = Run(*session, probe);
      if (type == "esrgan") {
        session->SetScale(width, height, output.cols, output.rows);
      } else if (output.size() != probe.size()) {
        throw Error("incompatible_model", "DeOldify image output must match its fixed input dimensions.");
      }
      session->validated = true;
    }
    metadata.remove_if([&](const Metadata& entry) { return entry.identity == metadata_identity; });
    metadata.push_front({metadata_identity, path, session->info});
    while (metadata.size() > 16) metadata.pop_back();
    sessions.push_front(std::move(session));
    return *sessions.front();
  }

  ModelInfo Info(const std::string& path, const std::string& type) {
    const std::string identity = KeyPart(FileIdentity(path)) + KeyPart(type);
    for (const auto& entry : metadata) {
      if (entry.identity == identity) return entry.info;
    }
    return GetSession(path, type, {}, false).info;
  }

  cv::Mat SuperResolve(Session& session, const cv::Mat& bgr) {
    const auto& info = session.info;
    Pixels(static_cast<int64_t>(bgr.cols) * info.scale, static_cast<int64_t>(bgr.rows) * info.scale);
    cv::Mat source;
    if (info.channels == 1) {
      cv::Mat ycrcb;
      cv::cvtColor(bgr, ycrcb, cv::COLOR_BGR2YCrCb);
      cv::extractChannel(ycrcb, source, 0);
    } else {
      cv::cvtColor(bgr, source, cv::COLOR_BGR2RGB);
    }
    source.convertTo(source, CV_32F, 1.0 / 255.0);
    const int tile_width = info.input_width ? info.input_width : kTile;
    const int tile_height = info.input_height ? info.input_height : kTile;
    const int pad_x = std::min(kOverlap, (tile_width - 1) / 4);
    const int pad_y = std::min(kOverlap, (tile_height - 1) / 4);
    const int core_width = tile_width - 2 * pad_x;
    const int core_height = tile_height - 2 * pad_y;
    cv::Mat result(bgr.rows * info.scale, bgr.cols * info.scale, source.type());
    for (int y = 0; y < bgr.rows; y += core_height) {
      for (int x = 0; x < bgr.cols; x += core_width) {
        CheckCancelled();
        const int width = std::min(core_width, bgr.cols - x);
        const int height = std::min(core_height, bgr.rows - y);
        const int left = std::max(0, x - pad_x);
        const int top = std::max(0, y - pad_y);
        const int right = std::min(bgr.cols, x + core_width + pad_x);
        const int bottom = std::min(bgr.rows, y + core_height + pad_y);
        const int border_left = pad_x - (x - left);
        const int border_top = pad_y - (y - top);
        cv::Mat tile;
        cv::copyMakeBorder(source(cv::Rect(left, top, right - left, bottom - top)), tile,
                           border_top, tile_height - (bottom - top) - border_top,
                           border_left, tile_width - (right - left) - border_left,
                           cv::BORDER_REPLICATE | cv::BORDER_ISOLATED);
        cv::Mat output = Run(session, tile);
        if (output.cols != tile_width * info.scale || output.rows != tile_height * info.scale) {
          throw Error("incompatible_model", "Model native scale changed between validation and tiled inference.");
        }
        output(cv::Rect(pad_x * info.scale, pad_y * info.scale, width * info.scale, height * info.scale))
            .copyTo(result(cv::Rect(x * info.scale, y * info.scale, width * info.scale, height * info.scale)));
      }
    }
    return result;
  }

  cv::Mat Colorize(Session& session, const cv::Mat& bgr) {
    if (IsNewColor(session.type)) return ColorizeModern(session, bgr);
    cv::Mat gray, input;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
    cv::cvtColor(gray, input, cv::COLOR_GRAY2RGB);
    cv::resize(input, input, cv::Size(session.info.input_width ? session.info.input_width : 256,
                                    session.info.input_height ? session.info.input_height : 256));
    input.convertTo(input, CV_32F);  // DeOldify Artistic consumes 0..255, not ImageNet normalization.
    cv::Mat prediction = Run(session, input);
    if (prediction.size() != input.size()) throw Error("incompatible_model", "DeOldify output dimensions do not match input.");
    // Preserve the existing Android artistic convention: swap BGR/RGB, then
    // interpret the swapped channels as BGR for Lab; original blue is target L.
    cv::cvtColor(prediction, prediction, cv::COLOR_BGR2RGB);
    prediction.convertTo(prediction, CV_32F, 1.0 / 255.0);
    cv::resize(prediction, prediction, bgr.size());
    cv::GaussianBlur(prediction, prediction, cv::Size(13, 13), 0);
    cv::Mat lab;
    cv::cvtColor(prediction, lab, cv::COLOR_BGR2Lab);
    std::vector<cv::Mat> planes;
    cv::split(lab, planes);
    cv::Mat chroma;
    cv::merge(std::vector<cv::Mat>{planes[1], planes[2]}, chroma);
    return chroma;  // Float a/b, no intensity multiplication or PNG roundtrip in the cache.
  }

  cv::Mat ColorizeModern(Session& session, const cv::Mat& bgr) {
    cv::Mat input;
    cv::Size content;
    if (session.type == "manga_v2") {
      // The upstream generator takes the first RGB channel, not a weighted
      // grayscale conversion. All four hint/mask planes are supplied as zero.
      cv::extractChannel(bgr, input, 2);
      const double ratio = 512.0 / std::max(bgr.cols, bgr.rows);
      content = cv::Size(std::max(32, static_cast<int>(std::lround(bgr.cols * ratio))),
                         std::max(32, static_cast<int>(std::lround(bgr.rows * ratio))));
      cv::resize(input, input, content, 0, 0, cv::INTER_LINEAR);
      const int width = session.info.input_width ? session.info.input_width : (content.width + 31) / 32 * 32;
      const int height = session.info.input_height ? session.info.input_height : (content.height + 31) / 32 * 32;
      cv::copyMakeBorder(input, input, 0, height - content.height, 0, width - content.width,
                         cv::BORDER_CONSTANT, cv::Scalar(255));
      input.convertTo(input, CV_32F, 1.0 / 255.0);
    } else if (session.type == "anime_deoldify") {
      // Approximate the upstream PIL resize -> LA -> RGB order with OpenCV.
      // The converted graph owns its learned mean/std normalization.
      cv::resize(bgr, input, cv::Size(256, 256), 0, 0, cv::INTER_LINEAR);
      cv::cvtColor(input, input, cv::COLOR_BGR2GRAY);
      cv::cvtColor(input, input, cv::COLOR_GRAY2RGB);
      input.convertTo(input, CV_32F);
    } else {
      cv::cvtColor(bgr, input, cv::COLOR_BGR2GRAY);
      if (session.type == "manga_light") {
        cv::resize(input, input, cv::Size(512, 512), 0, 0, cv::INTER_AREA);
        input.convertTo(input, CV_32F, 1.0 / 127.5, -1.0);
      } else {
        // FaceFusion DDColor preprocessing: gray RGB -> neutral float Lab ->
        // RGB, then resize. The graph performs its own input normalization.
        cv::cvtColor(input, input, cv::COLOR_GRAY2RGB);
        input.convertTo(input, CV_32F, 1.0 / 255.0);
        cv::cvtColor(input, input, cv::COLOR_RGB2Lab);
        for (int y = 0; y < input.rows; ++y) {
          auto* row = input.ptr<cv::Vec3f>(y);
          for (int x = 0; x < input.cols; ++x) row[x][1] = row[x][2] = 0;
        }
        cv::cvtColor(input, input, cv::COLOR_Lab2RGB);
        const int side = session.info.input_width ? session.info.input_width : 256;
        cv::resize(input, input, cv::Size(side, side), 0, 0, cv::INTER_LINEAR);
      }
    }
    cv::Mat prediction = Run(session, input);
    cv::Mat chroma;
    if (session.type == "ddcolor") {
      chroma = std::move(prediction);  // Raw float Lab a/b, never RGB or offset by 128.
    } else {
      if (session.type == "manga_v2") prediction = prediction(cv::Rect(cv::Point(), content));
      else if (session.type == "anime_deoldify") prediction.convertTo(prediction, CV_32F, 1.0 / 255.0);
      else prediction.convertTo(prediction, CV_32F, .5, .5);
      cv::max(prediction, 0, prediction);
      cv::min(prediction, 1, prediction);
      cv::Mat lab;
      cv::cvtColor(prediction, lab, cv::COLOR_RGB2Lab);
      chroma.create(lab.size(), CV_32FC2);
      const int mapping[] = {1, 0, 2, 1};
      cv::mixChannels(&lab, 1, &chroma, 1, mapping, 2);
    }
    if (chroma.size() != bgr.size()) cv::resize(chroma, chroma, bgr.size(), 0, 0, cv::INTER_LINEAR);
    return chroma;  // Cache unscaled chroma so concentration changes never rerun the model.
  }

  Base Infer(const Request& request, const Decoded& image, bool dml) {
    auto& session = GetSession(request.model_path, request.type, request.model_id, dml);
    const auto input_pixels = image.bgr.total();
    const auto native_pixels = request.type == "esrgan"
        ? input_pixels * session.info.scale * session.info.scale : input_pixels;
    const double scale = request.type == "esrgan"
        ? (request.output_scale == 0 ? session.info.scale : request.output_scale) : 1;
    const auto output_width = std::llround(image.bgr.cols * scale);
    const auto output_height = std::llround(image.bgr.rows * scale);
    Pixels(output_width, output_height);
    ValidateImageWorkingSet(input_pixels, native_pixels,
        static_cast<uint64_t>(output_width) * output_height);
    Base base;
    base.path = request.model_path;
    base.backend = session.backend;
    base.info = session.info;
    base.pixels = request.type == "esrgan" ? SuperResolve(session, image.bgr) : Colorize(session, image.bgr);
    return base;
  }

  cv::Mat RenderSr(const Request& request, const Decoded& original, const Base* base,
                   ModelInfo info, cv::Mat& output_alpha) {
    const double scale = request.output_scale == 0 ? info.scale : request.output_scale;
    if (scale < 1 || scale > info.scale) throw Error("invalid_arguments", "outputScale must be between 1 and the model native scale, or 0 for native.");
    const int64_t width = std::llround(original.bgr.cols * scale);
    const int64_t height = std::llround(original.bgr.rows * scale);
    Pixels(width, height);
    const cv::Size target(static_cast<int>(width), static_cast<int>(height));
    if (!original.alpha.empty()) cv::resize(original.alpha, output_alpha, target, 0, 0, cv::INTER_LINEAR);
    cv::Mat original_float;
    original.bgr.convertTo(original_float, CV_32F, 1.0 / 255.0);
    cv::Mat linear;
    if (request.strength < 1) linear = LinearResize(original_float, original.alpha, target, output_alpha);
    if (request.strength > 0) {
      cv::Mat enhanced;
      base->pixels.convertTo(enhanced, CV_32F, request.intensity, .5 * (1 - request.intensity));
      if (info.channels == 1) {
        cv::Mat ycrcb;
        cv::cvtColor(original_float, ycrcb, cv::COLOR_BGR2YCrCb);
        cv::resize(ycrcb, ycrcb, enhanced.size(), 0, 0, cv::INTER_CUBIC);
        cv::insertChannel(enhanced, ycrcb, 0);
        cv::cvtColor(ycrcb, enhanced, cv::COLOR_YCrCb2BGR);
      } else {
        cv::cvtColor(enhanced, enhanced, cv::COLOR_RGB2BGR);
      }
      cv::Mat native_alpha;
      if (!original.alpha.empty()) cv::resize(original.alpha, native_alpha, enhanced.size(), 0, 0, cv::INTER_LINEAR);
      cv::Mat ai_linear = LinearResize(enhanced, native_alpha, target, output_alpha);
      if (request.strength == 1) linear = std::move(ai_linear);
      else cv::addWeighted(linear, 1 - request.strength, ai_linear, request.strength, 0, linear);
    }
    for (int y = 0; y < linear.rows; ++y) {
      auto* row = linear.ptr<cv::Vec3f>(y);
      const auto* alpha = output_alpha.empty() ? nullptr : output_alpha.ptr<uint8_t>(y);
      for (int x = 0; x < linear.cols; ++x) {
        const float opacity = alpha ? alpha[x] / 255.0f : 1;
        for (int c = 0; c < 3; ++c) row[x][c] = opacity > 0 ? ToSrgb(row[x][c] / opacity) : 0;
      }
    }
    return linear;
  }

  cv::Mat RenderColor(const Request& request, const Decoded& image, const Base* base) {
    if (IsNewColor(request.type)) {
      cv::Mat lab, result;
      image.bgr.convertTo(lab, CV_32F, 1.0 / 255.0);
      cv::cvtColor(lab, lab, cv::COLOR_BGR2Lab);
      const float intensity = static_cast<float>(request.intensity);
      for (int y = 0; y < lab.rows; ++y) {
        auto* row = lab.ptr<cv::Vec3f>(y);
        const auto* chroma = intensity == 0 ? nullptr : base->pixels.ptr<cv::Vec2f>(y);
        for (int x = 0; x < lab.cols; ++x) {
          row[x][1] = chroma ? chroma[x][0] * intensity : 0;
          row[x][2] = chroma ? chroma[x][1] * intensity : 0;
        }
      }
      cv::cvtColor(lab, result, cv::COLOR_Lab2BGR);
      return result;
    }
    cv::Mat luminance;
    cv::extractChannel(image.bgr, luminance, 0);
    luminance.convertTo(luminance, CV_32F, 100.0 / 255.0);
    cv::Mat chroma;
    if (request.intensity == 0) chroma = cv::Mat::zeros(image.bgr.size(), CV_32FC2);
    else base->pixels.convertTo(chroma, CV_32F, request.intensity);
    std::vector<cv::Mat> planes;
    cv::split(chroma, planes);
    cv::Mat lab, result;
    cv::merge(std::vector<cv::Mat>{luminance, planes[0], planes[1]}, lab);
    cv::cvtColor(lab, result, cv::COLOR_Lab2BGR);
    return result;
  }
};

Engine::Engine() : impl_(std::make_unique<Impl>()) {}
Engine::~Engine() = default;

Capabilities Engine::GetCapabilities() {
  Capabilities result;
  try {
    impl_->DefaultRuntime();
#ifdef __APPLE__
    std::string reason;
    if (!AppleMetalAvailable(&reason)) throw Error("backend_unavailable", reason);
    result.backends = {"metal"};
#endif
  }
  catch (const std::exception& error) {
    result.supported = false;
    result.types.clear();
    result.backends.clear();
    result.reason = error.what();
    return result;
  }
#ifdef _WIN32
  try {
    auto& runtime = impl_->Dml();
    OrtOwner<OrtSessionOptions> options(nullptr, runtime.api->ReleaseSessionOptions);
    Check(runtime.api, runtime.api->CreateSessionOptions(&options.ptr));
    Check(runtime.api, runtime.dml->SessionOptionsAppendExecutionProvider_DML(options.ptr, 0));
    result.backends.push_back("directml");
  } catch (const std::exception& error) { result.reason = error.what(); }
#endif
  return result;
}

ModelInfo Engine::GetModelInfo(const std::string& path, const std::string& type) {
  impl_->CheckCancelled();
  return impl_->Info(path, type);
}

Result Engine::Process(const Request& request) {
  impl_->CheckCancelled();
#ifdef _WIN32
  const bool prefer_dml = request.backend == "auto";
#else
  const bool prefer_dml = false;
#endif
  CheckType(request.type);
#ifdef __APPLE__
  if (request.backend != "auto" && request.backend != "metal")
    throw Error("invalid_arguments", "Apple AI requires Metal; CPU neural inference is disabled.");
  const char* default_backend = "metal";
#else
  if (request.backend != "auto" && request.backend != "cpu") throw Error("invalid_arguments", "backend must be auto or cpu.");
  const char* default_backend = "cpu";
#endif
  if (!std::isfinite(request.intensity) || !std::isfinite(request.strength) || !std::isfinite(request.output_scale) ||
      request.intensity < (request.type == "esrgan" ? .3 : 0) || request.intensity > 1.2 ||
      request.strength < 0 || request.strength > 1 || request.output_scale < 0 || request.output_scale > 8) {
    throw Error("invalid_arguments", "Intensity, strength, or output scale is outside its supported range.");
  }
  if (request.input_id.empty() || request.model_id.empty()) throw Error("invalid_arguments", "Content-based inputId and modelId are required.");
  const uint64_t runs_before = impl_->inference_runs;
  const auto image = Decode(request.image_bytes);
  const bool bypass = request.type == "esrgan" ? request.strength == 0 : request.intensity == 0;
  const std::string key = KeyPart(request.input_id) + KeyPart(request.model_id) + KeyPart(FileIdentity(request.model_path)) + KeyPart(request.type);
  Impl::Base computed;
  Impl::Base* base = nullptr;
  bool hit = false;
  if (!bypass) {
    for (auto it = impl_->cache.begin(); it != impl_->cache.end(); ++it) {
      if (!request.force_reprocess && it->key == key && (!prefer_dml ? it->backend == default_backend
          : (it->backend == "directml" || !it->reason.empty()))) {
        impl_->cache.splice(impl_->cache.begin(), impl_->cache, it);
        base = &impl_->cache.front();
        hit = true;
        break;
      }
    }
    if (!base) {
      std::string reason;
      if (prefer_dml) {
        try { computed = impl_->Infer(request, image, true); }
        catch (const std::exception& error) {
          impl_->CheckCancelled();
          reason = std::string("DirectML unavailable or rejected this model: ") + error.what();
        }
      }
      if (computed.pixels.empty()) computed = impl_->Infer(request, image, false);
      computed.key = key;
      computed.reason = reason;
      base = &computed;
    }
  }
  ModelInfo info;
  if (base) info = base->info;
  else if (request.type == "esrgan") info = impl_->Info(request.model_path, request.type);
  const double output_scale = request.type == "esrgan"
      ? (request.output_scale == 0 ? info.scale : request.output_scale) : 1;
  const auto output_width = std::llround(image.bgr.cols * output_scale);
  const auto output_height = std::llround(image.bgr.rows * output_scale);
  Pixels(output_width, output_height);
  const uint64_t output_pixels = static_cast<uint64_t>(output_width) * output_height;
  ValidateImageWorkingSet(image.bgr.total(), 0,
      std::max<uint64_t>(output_pixels, base ? base->pixels.total() : 0));
  Result result;
  result.backend = bypass ? "none" : base->backend;
  result.scale = info.scale;
  result.cache_hit = hit;
  if (base) result.fallback_reason = base->reason;
  cv::Mat alpha = image.alpha;
  cv::Mat rendered = request.type == "esrgan"
      ? impl_->RenderSr(request, image, base, info, alpha)
      : impl_->RenderColor(request, image, base);
  impl_->CheckCancelled();
  result.image_bytes = Encode(rendered, alpha);
  result.inference_runs = impl_->inference_runs - runs_before;
  if (base == &computed && computed.Bytes() <= kCacheBytes) {
    for (auto it = impl_->cache.begin(); it != impl_->cache.end();) {
      if (it->key == computed.key && it->backend == computed.backend) {
        impl_->cache_bytes -= it->Bytes();
        it = impl_->cache.erase(it);
      } else ++it;
    }
    while (!impl_->cache.empty() && impl_->cache_bytes + computed.Bytes() > kCacheBytes) {
      impl_->cache_bytes -= impl_->cache.back().Bytes();
      impl_->cache.pop_back();
    }
    impl_->cache_bytes += computed.Bytes();
    impl_->cache.push_front(std::move(computed));
  }
  return result;
}

void Engine::Reset(const std::string& path) {
  impl_->sessions.remove_if([&](const auto& session) { return path.empty() || session->path == path; });
  impl_->metadata.remove_if([&](const auto& entry) { return path.empty() || entry.path == path; });
  for (auto it = impl_->cache.begin(); it != impl_->cache.end();) {
    if (path.empty() || it->path == path) {
      impl_->cache_bytes -= it->Bytes();
      it = impl_->cache.erase(it);
    } else ++it;
  }
  impl_->dml_checked = false;
  impl_->dml_error.clear();
  // Existing sessions retain runtime ownership; runtime itself is intentionally not unloaded here.
}

void Engine::Cancel() noexcept {
  impl_->cancelled.store(true);
  std::lock_guard<std::mutex> lock(impl_->run_mutex);
  if (impl_->active_run) {
    auto status = impl_->active_api->RunOptionsSetTerminate(impl_->active_run);
    if (status) impl_->active_api->ReleaseStatus(status);
  }
}

}  // namespace image_ai
