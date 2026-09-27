#include "bridge.h"
#include "engine.h"
#include "image_memory.h"

#include <glib.h>

#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace image_ai {
namespace {

constexpr size_t kMaxPending = 8;

// ---- Argument extraction from the standard-method-codec FlValue map ----

FlValue* AsMap(FlValue* args) {
  if (!args) return nullptr;
  const FlValueType type = fl_value_get_type(args);
  if (type == FL_VALUE_TYPE_NULL) return nullptr;
  if (type != FL_VALUE_TYPE_MAP)
    throw Error("invalid_arguments", "Image AI arguments must be a map.");
  return args;
}

FlValue* Find(FlValue* map, const char* key) {
  if (!map) return nullptr;
  const size_t length = fl_value_get_length(map);
  for (size_t i = 0; i < length; ++i) {
    FlValue* k = fl_value_get_map_key(map, i);
    if (fl_value_get_type(k) == FL_VALUE_TYPE_STRING &&
        g_strcmp0(fl_value_get_string(k), key) == 0) {
      return fl_value_get_map_value(map, i);
    }
  }
  return nullptr;
}

std::string String(FlValue* map, const char* key, bool required = true,
                   const char* fallback = "") {
  FlValue* value = Find(map, key);
  if (!value) {
    if (!required) return fallback;
    throw Error("invalid_arguments", std::string(key) + " must be a nonempty string.");
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    const char* text = fl_value_get_string(value);
    if (text && (!required || *text != '\0')) return text;
  }
  throw Error("invalid_arguments", std::string(key) + " must be a nonempty string.");
}

double Number(FlValue* map, const char* key, double fallback) {
  FlValue* value = Find(map, key);
  if (!value) return fallback;
  const FlValueType type = fl_value_get_type(value);
  if (type == FL_VALUE_TYPE_INT) return static_cast<double>(fl_value_get_int(value));
  if (type == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(value);
  throw Error("invalid_arguments", std::string(key) + " must be a number.");
}

bool Boolean(FlValue* map, const char* key, bool fallback = false) {
  FlValue* value = Find(map, key);
  if (!value) return fallback;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) return fl_value_get_bool(value);
  throw Error("invalid_arguments", std::string(key) + " must be a boolean.");
}

std::vector<uint8_t> Bytes(FlValue* map, const char* key) {
  FlValue* value = Find(map, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST)
    throw Error("invalid_arguments", std::string(key) + " must contain encoded image data.");
  const size_t length = fl_value_get_length(value);
  const uint8_t* data = fl_value_get_uint8_list(value);
  if (!data || length == 0)
    throw Error("invalid_arguments", std::string(key) + " must contain encoded image data.");
  return std::vector<uint8_t>(data, data + length);
}

// ---- Response value construction ----

FlValue* StringsValue(const std::vector<std::string>& values) {
  FlValue* list = fl_value_new_list();
  for (const auto& value : values)
    fl_value_append_take(list, fl_value_new_string(value.c_str()));
  return list;
}

}  // namespace

struct Bridge::Impl {
  struct Job {
    uint64_t id;
    std::string method;
    Request request;
    size_t Bytes() const { return request.image_bytes.size(); }
  };
  enum class ReplyKind { None, Capabilities, ModelInfo, Process };
  struct Reply {
    uint64_t id;
    ReplyKind kind = ReplyKind::None;
    Capabilities capabilities;
    ModelInfo info;
    Result result;
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
    Engine engine;

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
        Reply reply;
        reply.id = job.id;
        try {
          if (job.method == "getCapabilities") {
            reply.kind = ReplyKind::Capabilities;
            reply.capabilities = engine.GetCapabilities();
          } else if (job.method == "getModelInfo") {
            reply.kind = ReplyKind::ModelInfo;
            reply.info = engine.GetModelInfo(job.request.model_path, job.request.type);
          } else if (job.method == "resetSession") {
            engine.Reset(job.request.model_path);
            // Success with no payload; kind stays None.
          } else {
            reply.kind = ReplyKind::Process;
            reply.result = engine.Process(job.request);
          }
        } catch (const Error& error) {
          reply.code = error.code;
          reply.message = error.what();
        } catch (const std::bad_alloc&) {
          reply.code = "memory_limit";
          reply.message = "Native image processing ran out of memory.";
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
        }
        // The GLib idle source on the platform thread drains replies and
        // responds, mirroring the Windows HWND message pump.
      }
    }
  };

  struct Pending {
    FlMethodCall* call;  // owned reference; released after responding.
  };

  FlMethodChannel* channel;
  std::shared_ptr<Worker> worker;
  std::map<uint64_t, Pending> pending;
  uint64_t next_id = 1;
  guint drain_source = 0;

  Impl(FlBinaryMessenger* messenger) : worker(std::make_shared<Worker>()) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel = fl_method_channel_new(messenger, "com.cmanga.reader/colorize",
                                    FL_METHOD_CODEC(codec));
    g_object_unref(messenger);  // fl_engine_get_binary_messenger returned a new ref.
    fl_method_channel_set_method_call_handler(channel, OnCallThunk, this, nullptr);
    drain_source = g_idle_add(+[](gpointer user_data) -> gboolean {
      static_cast<Impl*>(user_data)->Drain();
      return G_SOURCE_CONTINUE;
    }, this);
    // Detached ownership is deliberate: closing the window never waits for model
    // construction or a device driver. The worker owns only native state and
    // releases itself after cancellation; Flutter results stay platform-owned.
    std::thread([state = worker] { state->Run(); }).detach();
  }

  ~Impl() {
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    g_clear_object(&channel);
    if (drain_source) {
      // Same thread as the idle callback: no concurrent access during destroy.
      g_source_remove(drain_source);
      drain_source = 0;
    }
    {
      std::lock_guard<std::mutex> lock(worker->mutex);
      worker->alive = false;
      worker->jobs.clear();
      worker->replies.clear();
      worker->queued_bytes = 0;
    }
    worker->engine.Cancel();
    worker->ready.notify_one();
    for (auto& entry : pending) {
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("cancelled",
                                       "Window closed before image AI processing completed.",
                                       nullptr));
      fl_method_call_respond(entry.second.call, response, nullptr);
      g_object_unref(entry.second.call);
    }
    pending.clear();
  }

  static void OnCallThunk(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
    static_cast<Impl*>(user_data)->OnCall(channel, call);
  }

  void OnCall(FlMethodChannel* channel, FlMethodCall* call) {
    const char* method = fl_method_call_get_name(call);
    const bool known = g_strcmp0(method, "getCapabilities") == 0 ||
                       g_strcmp0(method, "getModelInfo") == 0 ||
                       g_strcmp0(method, "resetSession") == 0 ||
                       g_strcmp0(method, "colorize") == 0;
    if (!known) {
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
          fl_method_not_implemented_response_new());
      fl_method_call_respond(call, response, nullptr);
      return;
    }
    try {
      if (pending.size() >= kMaxPending)
        throw Error("queue_full", "Image AI queue is full; wait for the current pages to finish.");
      FlValue* map = AsMap(fl_method_call_get_args(call));
      Job job;
      job.id = next_id++;
      job.method = method;
      if (g_strcmp0(method, "getModelInfo") == 0 || g_strcmp0(method, "colorize") == 0) {
        job.request.model_path = String(map, "modelPath");
        job.request.type = String(map, "type");
      } else if (g_strcmp0(method, "resetSession") == 0) {
        job.request.model_path = String(map, "modelPath", false);
      }
      if (g_strcmp0(method, "colorize") == 0) {
        std::vector<uint8_t> bytes = Bytes(map, "imageBytes");
        {
          std::lock_guard<std::mutex> lock(worker->mutex);
          const auto budget = ImageMemoryBudget() / 4;
          if (bytes.size() > budget || worker->queued_bytes > budget - bytes.size())
            throw Error("memory_limit", "Pending encoded images exceed available image memory.");
        }
        job.request.model_id = String(map, "modelId");
        job.request.input_id = String(map, "inputId");
        job.request.backend = String(map, "backend", false, "auto");
        job.request.intensity = Number(map, "intensity", 1);
        job.request.strength = Number(map, "strength", 1);
        job.request.output_scale = Number(map, "outputScale", 0);
        job.request.force_reprocess = Boolean(map, "forceReprocess");
        job.request.image_bytes = std::move(bytes);
      }
      // Keep an owned reference for the asynchronous response.
      g_object_ref(call);
      {
        std::lock_guard<std::mutex> lock(worker->mutex);
        worker->queued_bytes += job.Bytes();
        worker->jobs.push_back(std::move(job));
        pending.emplace(job.id, Pending{call});
      }
      worker->ready.notify_one();
    } catch (const Error& error) {
      RespondError(call, error.code, error.what());
    } catch (const std::exception& error) {
      RespondError(call, "image_ai_failed", error.what());
    }
  }

  static void RespondError(FlMethodCall* call, const std::string& code, const std::string& message) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new(code.c_str(), message.c_str(), nullptr));
    fl_method_call_respond(call, response, nullptr);
  }

  // Build the response value on the platform thread so the FlValue's
  // creation and finalization happen on the same thread (GLib finalization is
  // not safe across threads). The worker only returns plain data.
  static FlValue* BuildValue(const Reply& reply) {
    FlValue* map = fl_value_new_map();
    if (reply.kind == ReplyKind::Capabilities) {
      fl_value_set_string_take(map, "supported", fl_value_new_bool(reply.capabilities.supported));
      fl_value_set_string_take(map, "types", StringsValue(reply.capabilities.types));
      fl_value_set_string_take(map, "backends", StringsValue(reply.capabilities.backends));
      fl_value_set_string_take(
          map, "reason",
          reply.capabilities.reason.empty() ? fl_value_new_null()
                                            : fl_value_new_string(reply.capabilities.reason.c_str()));
    } else if (reply.kind == ReplyKind::ModelInfo) {
      fl_value_set_string_take(map, "channels", fl_value_new_int(reply.info.channels));
      fl_value_set_string_take(map, "scale", fl_value_new_int(reply.info.scale));
      fl_value_set_string_take(map, "inputWidth", fl_value_new_int(reply.info.input_width));
      fl_value_set_string_take(map, "inputHeight", fl_value_new_int(reply.info.input_height));
    } else if (reply.kind == ReplyKind::Process) {
      fl_value_set_string_take(
          map, "imageBytes",
          fl_value_new_uint8_list(reply.result.image_bytes.data(), reply.result.image_bytes.size()));
      fl_value_set_string_take(map, "backend", fl_value_new_string(reply.result.backend.c_str()));
      fl_value_set_string_take(map, "scale", fl_value_new_int(reply.result.scale));
      fl_value_set_string_take(map, "cacheHit", fl_value_new_bool(reply.result.cache_hit));
      fl_value_set_string_take(
          map, "fallbackReason",
          reply.result.fallback_reason.empty() ? fl_value_new_null()
                                               : fl_value_new_string(reply.result.fallback_reason.c_str()));
    }
    return map;
  }

  void Drain() {
    std::deque<Reply> replies;
    {
      std::lock_guard<std::mutex> lock(worker->mutex);
      replies.swap(worker->replies);
    }
    for (const auto& reply : replies) {
      auto it = pending.find(reply.id);
      if (it == pending.end()) continue;
      g_autoptr(FlMethodResponse) response;
      if (reply.code.empty()) {
        g_autoptr(FlValue) value = BuildValue(reply);
        // The success response takes its own reference; release ours.
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
      } else {
        response = FL_METHOD_RESPONSE(
            fl_method_error_response_new(reply.code.c_str(), reply.message.c_str(), nullptr));
      }
      fl_method_call_respond(it->second.call, response, nullptr);
      g_object_unref(it->second.call);
      pending.erase(it);
    }
  }
};

Bridge::Bridge(FlBinaryMessenger* messenger) : impl_(std::make_unique<Impl>(messenger)) {}
Bridge::~Bridge() = default;

}  // namespace image_ai
