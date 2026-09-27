#ifndef CMANGA_IMAGE_AI_ENGINE_H_
#define CMANGA_IMAGE_AI_ENGINE_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>

namespace image_ai {

class Error : public std::runtime_error {
 public:
  Error(std::string code, const std::string& message)
      : std::runtime_error(message), code(std::move(code)) {}
  const std::string code;
};

struct Capabilities {
  bool supported = true;
  std::vector<std::string> types{"esrgan", "deoldify", "manga_v2", "manga_light", "ddcolor", "anime_deoldify"};
  std::vector<std::string> backends{"cpu"};
  std::string reason;
};

struct ModelInfo {
  int channels = 0;
  int scale = 1;
  int input_width = 0;
  int input_height = 0;
};

struct Request {
  std::vector<uint8_t> image_bytes;
  std::string model_path;
  std::string model_id;
  std::string input_id;
  std::string type;
  std::string backend = "auto";
  double intensity = 1.0;
  double strength = 1.0;
  double output_scale = 0.0;
  bool force_reprocess = false;
};

struct Result {
  std::vector<uint8_t> image_bytes;
  std::string backend;
  std::string fallback_reason;
  int scale = 1;
  bool cache_hit = false;
  uint64_t inference_runs = 0;
};

// Serial worker API. Only Cancel may be called concurrently. No Flutter dependency.
class Engine {
 public:
  Engine();
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;
  Capabilities GetCapabilities();
  ModelInfo GetModelInfo(const std::string& model_path, const std::string& type);
  Result Process(const Request& request);
  void Reset(const std::string& model_path = {});
  void Cancel() noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace image_ai
#endif
