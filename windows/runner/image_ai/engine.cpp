#include "engine.h"

#include <onnxruntime_c_api.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <list>
#include <mutex>
#include <sstream>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dml_provider_factory.h>
#endif

namespace image_ai {
namespace {
constexpr size_t kCacheBytes = 128u * 1024u * 1024u;
constexpr int64_t kMaxPixels = 24ll * 1024 * 1024;
constexpr size_t kMaxEncodedBytes = 64u * 1024u * 1024u;
constexpr int kTile = 256;
constexpr int kOverlap = 24;

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
  if (width < 1 || height < 1 || width > kMaxPixels || height > kMaxPixels ||
      width * height > kMaxPixels) {
    throw Error("image_too_large", "AI output exceeds the 24 megapixel memory limit; choose a smaller input or model. Native inference is never silently downscaled.");
  }
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
  return name + ":" + std::to_string(size) + ":" + std::to_string(modified.time_since_epoch().count());
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
        if (!api) throw Error("backend_unavailable", "CPU ONNX Runtime API version does not match this application.");
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
  std::string input_name;
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
    Check(api, api->SetSessionGraphOptimizationLevel(options.ptr, ORT_ENABLE_ALL));
    Check(api, api->SetIntraOpNumThreads(options.ptr, 4));
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
    size_t inputs = 0, outputs = 0;
    Check(api, api->SessionGetInputCount(created.ptr, &inputs));
    Check(api, api->SessionGetOutputCount(created.ptr, &outputs));
    if (inputs != 1 || outputs != 1) throw Error("incompatible_model", "Expected exactly one image input and one image output.");
    OrtAllocator* allocator = nullptr;
    Check(api, api->GetAllocatorWithDefaultOptions(&allocator));
    auto name = [&](bool input) {
      char* value = nullptr;
      Check(api, input ? api->SessionGetInputName(created.ptr, 0, allocator, &value)
                       : api->SessionGetOutputName(created.ptr, 0, allocator, &value));
      std::string result(value);
      allocator->Free(allocator, value);
      return result;
    };
    input_name = name(true);
    output_name = name(false);
    auto shape = [&](bool input) {
      OrtOwner<OrtTypeInfo> type_info(nullptr, api->ReleaseTypeInfo);
      Check(api, input ? api->SessionGetInputTypeInfo(created.ptr, 0, &type_info.ptr)
                       : api->SessionGetOutputTypeInfo(created.ptr, 0, &type_info.ptr));
      const OrtTensorTypeAndShapeInfo* tensor = nullptr;
      Check(api, api->CastTypeInfoToTensorInfo(type_info.ptr, &tensor));
      if (!tensor) throw Error("incompatible_model", "Image input/output must be tensors.");
      ONNXTensorElementDataType element;
      Check(api, api->GetTensorElementType(tensor, &element));
      if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        throw Error("incompatible_model", "Expected float32 NCHW image input/output. Int8-weight models with float32 image I/O are supported; raw quantized I/O requires an explicit quantization contract.");
      }
      size_t rank = 0;
      Check(api, api->GetDimensionsCount(tensor, &rank));
      if (rank != 4) throw Error("incompatible_model", "Expected rank-four NCHW image tensors.");
      std::array<int64_t, 4> dims;
      Check(api, api->GetDimensions(tensor, dims.data(), dims.size()));
      if (dims[0] > 1) throw Error("incompatible_model", "Only batch-one image models are supported.");
      return dims;
    };
    const auto input = shape(true);
    output_shape = shape(false);
    if ((input[1] != 1 && input[1] != 3) ||
        (kind == "deoldify" && input[1] != 3) ||
        (output_shape[1] > 0 && output_shape[1] != input[1])) {
      throw Error("incompatible_model", "Expected ACNet (1 channel), RGB SR (3 channels), or DeOldify (3 channels), with matching output channels.");
    }
    info.channels = static_cast<int>(input[1]);
    if (input[2] > 2048 || input[3] > 2048) throw Error("incompatible_model", "Fixed model input exceeds the supported 2048-pixel side.");
    info.input_height = input[2] > 0 ? static_cast<int>(input[2]) : 0;
    info.input_width = input[3] > 0 ? static_cast<int>(input[3]) : 0;
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
  if (bytes.empty() || bytes.size() > kMaxEncodedBytes) throw Error("invalid_image", "Encoded image must be between 1 byte and 64 MiB.");
  cv::Mat image = cv::imdecode(bytes, cv::IMREAD_UNCHANGED);
  if (image.empty()) throw Error("invalid_image", "Image could not be decoded.");
  Pixels(image.cols, image.rows);
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
  std::unique_ptr<Runtime> cpu;
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
  Runtime& Cpu() {
    if (!cpu) cpu = std::make_unique<Runtime>(false);
    return *cpu;
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
    const int channels = input.channels();
    const size_t plane = input.total();
    std::vector<float> buffer(plane * channels);
    for (int y = 0; y < input.rows; ++y) {
      const float* src = input.ptr<float>(y);
      for (int x = 0; x < input.cols; ++x) {
        for (int c = 0; c < channels; ++c) buffer[c * plane + y * input.cols + x] = src[x * channels + c];
      }
    }
    const std::array<int64_t, 4> shape{1, channels, input.rows, input.cols};
    OrtOwner<OrtMemoryInfo> memory(nullptr, api->ReleaseMemoryInfo);
    Check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory.ptr));
    OrtOwner<OrtValue> tensor(nullptr, api->ReleaseValue);
    Check(api, api->CreateTensorWithDataAsOrtValue(memory.ptr, buffer.data(), buffer.size() * sizeof(float),
                                                 shape.data(), shape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor.ptr));
    OrtOwner<OrtRunOptions> run(nullptr, api->ReleaseRunOptions);
    Check(api, api->CreateRunOptions(&run.ptr));
    const char* input_name = model.input_name.c_str();
    const char* output_name = model.output_name.c_str();
    const OrtValue* input_value = tensor.ptr;
    OrtOwner<OrtValue> output(nullptr, api->ReleaseValue);
    {
      std::lock_guard<std::mutex> lock(run_mutex);
      CheckCancelled();
      active_api = api;
      active_run = run.ptr;
    }
    OrtStatus* status = api->Run(model.session, run.ptr, &input_name, &input_value, 1, &output_name, 1, &output.ptr);
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
    if (rank != 4) throw Error("incompatible_model", "Inference output is not NCHW.");
    std::array<int64_t, 4> output_shape;
    Check(api, api->GetDimensions(dimensions.ptr, output_shape.data(), output_shape.size()));
    if (output_shape[0] != 1 || output_shape[1] != channels) throw Error("incompatible_model", "Inference output batch/channel mismatch.");
    Pixels(output_shape[3], output_shape[2]);
    float* data = nullptr;
    Check(api, api->GetTensorMutableData(output.ptr, reinterpret_cast<void**>(&data)));
    const int width = static_cast<int>(output_shape[3]);
    const int height = static_cast<int>(output_shape[2]);
    cv::Mat result(height, width, CV_MAKETYPE(CV_32F, channels));
    const size_t output_plane = result.total();
    for (int y = 0; y < height; ++y) {
      float* dst = result.ptr<float>(y);
      for (int x = 0; x < width; ++x) {
        for (int c = 0; c < channels; ++c) {
          const float value = data[c * output_plane + y * width + x];
          if (!std::isfinite(value)) throw Error("inference_failed", "Model produced non-finite pixels.");
          dst[x * channels + c] = value;
        }
      }
    }
    return result;
  }

  Session& GetSession(const std::string& path, const std::string& type,
                      const std::string& model_id, bool dml) {
    if (type != "esrgan" && type != "deoldify") throw Error("unsupported_type", "Only esrgan and deoldify are supported.");
    const std::string file_identity = KeyPart(FileIdentity(path));
    const std::string suffix = KeyPart(type) + (dml ? "dml" : "cpu");
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
    while (sessions.size() >= 2) sessions.pop_back();
    auto session = std::make_unique<Session>(dml ? Dml() : Cpu(), path, type, identity, dml);
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
      metadata.push_front({metadata_identity, path, session->info});
      while (metadata.size() > 16) metadata.pop_back();
    }
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

  Base Infer(const Request& request, const Decoded& image, bool dml) {
    auto& session = GetSession(request.model_path, request.type, request.model_id, dml);
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
  try { impl_->Cpu(); }
  catch (const std::exception& error) {
    result.supported = false;
    result.types.clear();
    result.backends.clear();
    result.reason = error.what();
    return result;
  }
  try {
    auto& runtime = impl_->Dml();
#ifdef _WIN32
    OrtOwner<OrtSessionOptions> options(nullptr, runtime.api->ReleaseSessionOptions);
    Check(runtime.api, runtime.api->CreateSessionOptions(&options.ptr));
    Check(runtime.api, runtime.dml->SessionOptionsAppendExecutionProvider_DML(options.ptr, 0));
#endif
    result.backends.push_back("directml");
  } catch (const std::exception& error) { result.reason = error.what(); }
  return result;
}

ModelInfo Engine::GetModelInfo(const std::string& path, const std::string& type) {
  return impl_->Info(path, type);
}

Result Engine::Process(const Request& request) {
  impl_->CheckCancelled();
  if (request.type != "esrgan" && request.type != "deoldify") throw Error("unsupported_type", "Only esrgan and deoldify are supported.");
  if (request.backend != "auto" && request.backend != "cpu") throw Error("invalid_arguments", "backend must be auto or cpu.");
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
      if (it->key == key && (request.backend == "cpu" ? it->backend == "cpu"
          : (it->backend == "directml" || !it->reason.empty()))) {
        impl_->cache.splice(impl_->cache.begin(), impl_->cache, it);
        base = &impl_->cache.front();
        hit = true;
        break;
      }
    }
    if (!base) {
      std::string reason;
      if (request.backend == "auto") {
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
