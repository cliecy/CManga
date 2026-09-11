#include "engine.h"
#include <opencv2/imgcodecs.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <iostream>
#include <map>
#include <sstream>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#pragma comment(lib, "psapi.lib")
#else
#include <sys/resource.h>
#endif

namespace {
// Streaming SHA-256 keeps multi-hundred-megabyte models out of smoke's working set.
class Sha256 {
 public:
  void Add(const uint8_t* data, size_t size) {
    bytes_ += size;
    while (size) {
      const size_t count = std::min(size, block_.size() - used_);
      std::memcpy(block_.data() + used_, data, count);
      used_ += count;
      data += count;
      size -= count;
      if (used_ == 64) { Compress(); used_ = 0; }
    }
  }
  std::string Finish() {
    const uint64_t bits = bytes_ * 8;
    const uint8_t start = 0x80, zero = 0;
    Add(&start, 1);
    while (used_ != 56) Add(&zero, 1);
    std::array<uint8_t, 8> length;
    for (int i = 0; i < 8; ++i) length[7 - i] = static_cast<uint8_t>(bits >> (8 * i));
    Add(length.data(), length.size());
    std::ostringstream out;
    for (auto word : state_) out << std::hex << std::setw(8) << std::setfill('0') << word;
    return out.str();
  }
 private:
  static uint32_t Rotate(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
  void Compress() {
    static constexpr uint32_t k[] = {
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
      w[i] = (uint32_t(block_[i * 4]) << 24) | (uint32_t(block_[i * 4 + 1]) << 16) |
             (uint32_t(block_[i * 4 + 2]) << 8) | block_[i * 4 + 3];
    }
    for (int i = 16; i < 64; ++i) {
      const uint32_t a = w[i - 15], b = w[i - 2];
      w[i] = w[i - 16] + (Rotate(a, 7) ^ Rotate(a, 18) ^ (a >> 3)) + w[i - 7] + (Rotate(b, 17) ^ Rotate(b, 19) ^ (b >> 10));
    }
    auto s = state_;
    for (int i = 0; i < 64; ++i) {
      const uint32_t t1 = s[7] + (Rotate(s[4], 6) ^ Rotate(s[4], 11) ^ Rotate(s[4], 25)) +
          ((s[4] & s[5]) ^ (~s[4] & s[6])) + k[i] + w[i];
      const uint32_t t2 = (Rotate(s[0], 2) ^ Rotate(s[0], 13) ^ Rotate(s[0], 22)) +
          ((s[0] & s[1]) ^ (s[0] & s[2]) ^ (s[1] & s[2]));
      s = {t1 + t2, s[0], s[1], s[2], s[3] + t1, s[4], s[5], s[6]};
    }
    for (int i = 0; i < 8; ++i) state_[i] += s[i];
  }
  std::array<uint32_t, 8> state_{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  std::array<uint8_t, 64> block_{};
  size_t used_ = 0;
  uint64_t bytes_ = 0;
};

std::string HashFile(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Cannot open file for hashing: " + path.u8string());
  std::array<uint8_t, 65536> buffer;
  Sha256 hash;
  while (file) {
    file.read(reinterpret_cast<char*>(buffer.data()), buffer.size());
    hash.Add(buffer.data(), static_cast<size_t>(file.gcount()));
  }
  if (!file.eof()) throw std::runtime_error("File read failed: " + path.u8string());
  return hash.Finish();
}
std::string Json(const std::string& value) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c);
    else out << c;
  }
  out << '"';
  return out.str();
}
uint64_t PeakMemory() {
#ifdef _WIN32
  PROCESS_MEMORY_COUNTERS counters{};
  return GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters)) ? counters.PeakWorkingSetSize : 0;
#elif defined(__APPLE__)
  rusage usage{};
  return getrusage(RUSAGE_SELF, &usage) == 0 ? static_cast<uint64_t>(usage.ru_maxrss) : 0;
#else
  rusage usage{};
  return getrusage(RUSAGE_SELF, &usage) == 0 ? static_cast<uint64_t>(usage.ru_maxrss) * 1024 : 0;
#endif
}

int Run(const std::vector<std::string>& arguments) {
  std::map<std::string, std::string> options;
  for (size_t i = 1; i < arguments.size(); i += 2) {
    if (i + 1 >= arguments.size() || arguments[i].rfind("--", 0) != 0) {
      throw std::runtime_error("Usage: cmanga_image_ai_smoke --model PATH --image PATH --output PATH --type esrgan|deoldify|manga_v2|manga_light|ddcolor|anime_deoldify [--backend metal|cpu|auto] [--scale 1.3] [--strength 1] [--intensity 1] [--renders 3] [--check-strength true|false (esrgan only)]. Color intensity is 0..1.2; all color types retain input dimensions and alpha.");
    }
    static constexpr const char* keys[] = {"--model", "--image", "--output", "--type", "--backend",
        "--scale", "--strength", "--intensity", "--renders", "--check-strength"};
    if (std::find(std::begin(keys), std::end(keys), arguments[i]) == std::end(keys)) {
      throw std::runtime_error("Unknown option: " + arguments[i]);
    }
    if (options.count(arguments[i])) throw std::runtime_error("Duplicate option: " + arguments[i]);
    options[arguments[i]] = arguments[i + 1];
  }
  auto required = [&](const char* key) -> std::string {
    const auto it = options.find(key);
    if (it == options.end()) throw std::runtime_error(std::string("Missing ") + key);
    return it->second;
  };
  auto optional = [&](const char* key, const char* fallback) -> std::string {
    const auto it = options.find(key);
    return it == options.end() ? fallback : it->second;
  };
  image_ai::Request request;
  request.model_path = required("--model");
  request.type = required("--type");
  const auto supported_types = image_ai::Capabilities{}.types;
  if (std::find(supported_types.begin(), supported_types.end(), request.type) == supported_types.end()) {
    throw std::runtime_error("--type must be esrgan, deoldify, manga_v2, manga_light, ddcolor, or anime_deoldify.");
  }
  const std::string check_strength_option = optional("--check-strength", "false");
  if (check_strength_option != "true" && check_strength_option != "false") {
    throw std::runtime_error("--check-strength must be true or false.");
  }
  const bool check_strength = check_strength_option == "true";
  if (check_strength && request.type != "esrgan") {
    throw std::runtime_error("--check-strength requires esrgan; color models use --intensity, not SR blend strength.");
  }
#ifdef __APPLE__
  request.backend = optional("--backend", "metal");
#else
  request.backend = optional("--backend", "cpu");
#endif
  request.output_scale = std::stod(optional("--scale", "0"));
  request.strength = std::stod(optional("--strength", "1"));
  request.intensity = std::stod(optional("--intensity", "1"));
  const int renders = std::stoi(optional("--renders", "1"));
  if (renders < 1 || renders > 20) throw std::runtime_error("renders must be between 1 and 20.");
  const auto input_path = std::filesystem::u8path(required("--image"));
  const auto output_path = std::filesystem::u8path(required("--output"));
  request.model_id = HashFile(std::filesystem::u8path(request.model_path));
  request.input_id = HashFile(input_path);
  std::ifstream image(input_path, std::ios::binary | std::ios::ate);
  if (!image || image.tellg() < 1 || image.tellg() > 64 * 1024 * 1024) throw std::runtime_error("Image file size is invalid.");
  request.image_bytes.resize(static_cast<size_t>(image.tellg()));
  image.seekg(0);
  image.read(reinterpret_cast<char*>(request.image_bytes.data()), request.image_bytes.size());
  if (!image) throw std::runtime_error("Image read failed.");
  const cv::Mat original = cv::imdecode(request.image_bytes, cv::IMREAD_UNCHANGED);
  image_ai::Engine engine;
  const auto capabilities = engine.GetCapabilities();
  if (!capabilities.supported) throw image_ai::Error("backend_unavailable", capabilities.reason);
  const auto info = engine.GetModelInfo(request.model_path, request.type);
  const double original_strength = request.strength, original_intensity = request.intensity;
  for (int render = 0; render < renders; ++render) {
    if (render > 0) {
      request.strength = original_strength * (render % 2 ? .5 : 1);
      request.intensity = original_intensity * (render % 2 ? 1 : .8);
      if (request.type == "esrgan") request.intensity = std::max(.3, request.intensity);
    }
    const auto start = std::chrono::steady_clock::now();
    auto result = engine.Process(request);
    const auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    const cv::Mat decoded = cv::imdecode(result.image_bytes, cv::IMREAD_UNCHANGED);
    if (decoded.empty()) throw std::runtime_error("Engine returned an invalid PNG.");
    auto destination = output_path;
    if (render) destination = output_path.parent_path() / (output_path.stem().u8string() + "-" + std::to_string(render) + output_path.extension().u8string());
    std::ofstream output(destination, std::ios::binary);
    output.write(reinterpret_cast<const char*>(result.image_bytes.data()), result.image_bytes.size());
    output.close();
    if (!output) throw std::runtime_error("Cannot write output PNG.");
    std::cout << "{\"render\":" << render << ",\"type\":" << Json(request.type) << ",\"backend\":" << Json(result.backend)
              << ",\"width\":" << decoded.cols << ",\"height\":" << decoded.rows
              << ",\"inputWidth\":" << original.cols << ",\"inputHeight\":" << original.rows
              << ",\"scale\":" << result.scale << ",\"outputScale\":" << request.output_scale
              << ",\"strength\":" << request.strength << ",\"intensity\":" << request.intensity
              << ",\"channels\":" << info.channels << ",\"cacheHit\":" << (result.cache_hit ? "true" : "false")
              << ",\"inferenceRuns\":" << result.inference_runs << ",\"elapsedMs\":" << elapsed
              << ",\"peakMemoryBytes\":" << PeakMemory()
              << ",\"modelSha256\":" << Json(request.model_id) << ",\"inputSha256\":" << Json(request.input_id)
              << ",\"fallbackReason\":" << (result.fallback_reason.empty() ? "null" : Json(result.fallback_reason))
              << ",\"output\":" << Json(destination.u8string()) << "}" << std::endl;
  }
  if (check_strength) {
    request.intensity = original_intensity;
    std::array<cv::Mat, 3> images;
    constexpr double strengths[] = {0, 1, .5};
    for (size_t i = 0; i < images.size(); ++i) {
      request.strength = strengths[i];
      images[i] = cv::imdecode(engine.Process(request).image_bytes, cv::IMREAD_UNCHANGED);
      if (images[i].empty() || images[i].size() != images[0].size() ||
          images[i].type() != images[0].type()) throw std::runtime_error("Strength changed image layout");
    }
    const auto linear = [](uint8_t byte) {
      const double value = byte / 255.0;
      return value <= .04045 ? value / 12.92 : std::pow((value + .055) / 1.055, 2.4);
    };
    for (int y = 0; y < images[0].rows; ++y) {
      const auto* base = images[0].ptr<uint8_t>(y);
      const auto* full = images[1].ptr<uint8_t>(y);
      const auto* half = images[2].ptr<uint8_t>(y);
      const int channels = images[0].channels();
      for (int x = 0; x < images[0].cols; ++x) {
        for (int c = 0; c < 3; ++c) {
          const int index = x * channels + c;
          const double mixed = .5 * (linear(base[index]) + linear(full[index]));
          const double expected = 255 * (mixed <= .0031308 ? 12.92 * mixed
              : 1.055 * std::pow(mixed, 1.0 / 2.4) - .055);
          // Endpoint and result PNGs each quantize once. Large differences
          // catch invalid cubic overshoot being mixed before endpoint clipping.
          if (std::abs(half[index] - expected) > 2) {
            throw std::runtime_error("Half strength is not the linear-light midpoint of its endpoints");
          }
        }
        if (channels == 4 && (base[x * 4 + 3] != full[x * 4 + 3] ||
            base[x * 4 + 3] != half[x * 4 + 3])) {
          throw std::runtime_error("Strength changed output alpha");
        }
      }
    }
  }
  return 0;
}
}  // namespace

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
#else
int main(int argc, char** argv) {
#endif
  try {
    std::vector<std::string> arguments;
    for (int i = 0; i < argc; ++i) {
#ifdef _WIN32
      arguments.push_back(std::filesystem::path(argv[i]).u8string());
#else
      arguments.emplace_back(argv[i]);
#endif
    }
    return Run(arguments);
  } catch (const image_ai::Error& error) {
    std::cerr << "{\"error\":" << Json(error.code) << ",\"message\":" << Json(error.what()) << "}" << std::endl;
  } catch (const std::exception& error) {
    std::cerr << "{\"error\":\"smoke_failed\",\"message\":" << Json(error.what()) << "}" << std::endl;
  }
  return 1;
}
