#include "bridge.h"
#include "engine.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <utility>

namespace image_ai {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using MethodResult = flutter::MethodResult<Value>;
constexpr size_t kMaxPending = 8;
constexpr size_t kMaxQueuedBytes = 128u * 1024u * 1024u;

const Value* Find(const Map& args, const char* key) {
  auto found = args.find(Value(key));
  return found == args.end() ? nullptr : &found->second;
}
std::string String(const Map& args, const char* key, bool required = true, const char* fallback = "") {
  const auto value = Find(args, key);
  if (!value && !required) return fallback;
  if (value) {
    if (const auto text = std::get_if<std::string>(value); text && (!required || !text->empty())) return *text;
  }
  throw Error("invalid_arguments", std::string(key) + " must be a nonempty string.");
}
double Number(const Map& args, const char* key, double fallback) {
  const auto value = Find(args, key);
  if (!value) return fallback;
  if (const auto number = std::get_if<double>(value)) return *number;
  if (const auto number = std::get_if<int32_t>(value)) return *number;
  if (const auto number = std::get_if<int64_t>(value)) return static_cast<double>(*number);
  throw Error("invalid_arguments", std::string(key) + " must be a number.");
}
Value OptionalString(const std::string& value) { return value.empty() ? Value() : Value(value); }
Value Strings(const std::vector<std::string>& values) {
  flutter::EncodableList list;
  for (const auto& value : values) list.emplace_back(value);
  return Value(std::move(list));
}
}  // namespace

struct Bridge::Impl {
  struct Job {
    uint64_t id;
    std::string method;
    Request request;
    size_t Bytes() const { return request.image_bytes.size(); }
  };
  struct Reply {
    uint64_t id;
    Value value;
    std::string code;
    std::string message;
  };
  struct Worker {
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<Job> jobs;
    std::deque<Reply> replies;
    size_t queued_bytes = 0;
    bool alive = true;
    HWND window;
    Engine engine;
    explicit Worker(HWND handle) : window(handle) {}

    void Run() {
      for (;;) {
        Job job;
        {
          std::unique_lock<std::mutex> lock(mutex);
          ready.wait(lock, [&] { return !alive || !jobs.empty(); });
          if (!alive) return;
          job = std::move(jobs.front());
          jobs.pop_front();
          queued_bytes -= job.Bytes();
        }
        Reply reply{job.id, Value(), {}, {}};
        try {
          if (job.method == "getCapabilities") {
            auto capabilities = engine.GetCapabilities();
            reply.value = Map{{Value("supported"), Value(capabilities.supported)},
                              {Value("types"), Strings(capabilities.types)},
                              {Value("backends"), Strings(capabilities.backends)},
                              {Value("reason"), OptionalString(capabilities.reason)}};
          } else if (job.method == "getModelInfo") {
            const auto info = engine.GetModelInfo(job.request.model_path, job.request.type);
            reply.value = Map{{Value("channels"), Value(info.channels)}, {Value("scale"), Value(info.scale)},
                              {Value("inputWidth"), Value(info.input_width)}, {Value("inputHeight"), Value(info.input_height)}};
          } else if (job.method == "resetSession") {
            engine.Reset(job.request.model_path);
          } else {
            auto output = engine.Process(job.request);
            reply.value = Map{{Value("imageBytes"), Value(std::move(output.image_bytes))},
                              {Value("backend"), Value(output.backend)}, {Value("scale"), Value(output.scale)},
                              {Value("cacheHit"), Value(output.cache_hit)},
                              {Value("fallbackReason"), OptionalString(output.fallback_reason)}};
          }
        } catch (const Error& error) {
          reply.code = error.code;
          reply.message = error.what();
        } catch (const std::exception& error) {
          reply.code = "image_ai_failed";
          reply.message = error.what();
        } catch (...) {
          reply.code = "image_ai_failed";
          reply.message = "Unknown native image processing failure.";
        }
        {
          std::lock_guard<std::mutex> lock(mutex);
          if (!alive) return;
          replies.push_back(std::move(reply));
          // Lock couples HWND use with shutdown. No raw result/channel/bridge
          // pointer crosses the worker boundary, including already-posted messages.
          PostMessageW(window, Bridge::kCompletionMessage, 0, 0);
        }
      }
    }
  };

  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  std::shared_ptr<Worker> worker;
  std::map<uint64_t, std::unique_ptr<MethodResult>> pending;
  uint64_t next_id = 1;

  Impl(flutter::BinaryMessenger* messenger, HWND window)
      : worker(std::make_shared<Worker>(window)) {
    channel = std::make_unique<flutter::MethodChannel<Value>>(
        messenger, "com.github.kiastr.venera_ssr/colorize", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, std::unique_ptr<MethodResult> result) {
      Accept(call, std::move(result));
    });
    // Detached ownership is deliberate: closing the window never waits for model
    // construction or a device driver. Worker owns only native state, and releases
    // itself after cancellation; Flutter results remain platform-thread-owned.
    std::thread([state = worker] { state->Run(); }).detach();
  }
  ~Impl() {
    channel->SetMethodCallHandler(nullptr);
    {
      std::lock_guard<std::mutex> lock(worker->mutex);
      worker->alive = false;
      worker->jobs.clear();
      worker->replies.clear();
      worker->queued_bytes = 0;
    }
    worker->engine.Cancel();
    worker->ready.notify_one();
    for (auto& entry : pending) entry.second->Error("cancelled", "Window closed before image AI processing completed.");
    pending.clear();
  }

  void Accept(const flutter::MethodCall<Value>& call, std::unique_ptr<MethodResult> result) {
    const auto& method = call.method_name();
    if (method != "getCapabilities" && method != "getModelInfo" && method != "resetSession" && method != "colorize") {
      result->NotImplemented();
      return;
    }
    try {
      if (pending.size() >= kMaxPending) throw Error("queue_full", "Image AI queue is full; wait for the current pages to finish.");
      const Map empty;
      const auto arguments = call.arguments();
      const auto map = arguments ? std::get_if<Map>(arguments) : nullptr;
      if (arguments && !std::holds_alternative<std::monostate>(*arguments) && !map) throw Error("invalid_arguments", "Image AI arguments must be a map.");
      const Map& args = map ? *map : empty;
      Job job;
      job.id = next_id++;
      job.method = method;
      if (method == "getModelInfo" || method == "colorize") {
        job.request.model_path = String(args, "modelPath");
        job.request.type = String(args, "type");
      } else if (method == "resetSession") {
        job.request.model_path = String(args, "modelPath", false);
      }
      if (method == "colorize") {
        const auto bytes_value = Find(args, "imageBytes");
        const auto bytes = bytes_value ? std::get_if<std::vector<uint8_t>>(bytes_value) : nullptr;
        if (!bytes || bytes->empty() || bytes->size() > 64u * 1024u * 1024u) throw Error("invalid_arguments", "imageBytes must contain 1 byte to 64 MiB of encoded image data.");
        {
          std::lock_guard<std::mutex> lock(worker->mutex);
          if (worker->queued_bytes + bytes->size() > kMaxQueuedBytes) throw Error("queue_full", "Queued image bytes exceed the 128 MiB limit.");
        }
        job.request.model_id = String(args, "modelId");
        job.request.input_id = String(args, "inputId");
        job.request.backend = String(args, "backend", false, "auto");
        job.request.intensity = Number(args, "intensity", 1);
        job.request.strength = Number(args, "strength", 1);
        job.request.output_scale = Number(args, "outputScale", 0);
        job.request.image_bytes = *bytes;
      }
      {
        std::lock_guard<std::mutex> lock(worker->mutex);
        worker->queued_bytes += job.Bytes();
        const auto id = job.id;
        worker->jobs.push_back(std::move(job));
        pending.emplace(id, std::move(result));
      }
      worker->ready.notify_one();
    } catch (const Error& error) {
      result->Error(error.code, error.what());
    } catch (const std::exception& error) {
      result->Error("image_ai_failed", error.what());
    }
  }
  void Drain() {
    std::deque<Reply> replies;
    {
      std::lock_guard<std::mutex> lock(worker->mutex);
      replies.swap(worker->replies);
    }
    for (auto& reply : replies) {
      auto it = pending.find(reply.id);
      if (it == pending.end()) continue;
      if (reply.code.empty()) it->second->Success(reply.value);
      else it->second->Error(reply.code, reply.message);
      pending.erase(it);
    }
  }
};

Bridge::Bridge(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}
Bridge::~Bridge() = default;
void Bridge::DrainReplies() { impl_->Drain(); }

}  // namespace image_ai
