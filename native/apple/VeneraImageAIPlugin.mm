#import "VeneraImageAIPlugin.h"

#include "../image_ai/engine.h"
#include "../image_ai/image_memory.h"
#include "metal_provider.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>

namespace {
#if TARGET_OS_IOS
constexpr NSUInteger kMaxPending = 4;
#else
constexpr NSUInteger kMaxPending = 8;
#endif

NSString* Text(const std::string& value) {
  return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"Invalid native UTF-8 message";
}
id OptionalText(const std::string& value) { return value.empty() ? [NSNull null] : Text(value); }
NSArray* Strings(const std::vector<std::string>& values) {
  NSMutableArray* result = [NSMutableArray arrayWithCapacity:values.size()];
  for (const auto& value : values) [result addObject:Text(value)];
  return result;
}
std::string String(NSDictionary* args, NSString* key, bool required = true, const char* fallback = "") {
  id value = args[key];
  if (!value && !required) return fallback;
  if (![value isKindOfClass:[NSString class]] || (required && ![value length])) {
    throw image_ai::Error("invalid_arguments", std::string(key.UTF8String) + " must be a nonempty string.");
  }
  NSData* utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (!utf8 || memchr(utf8.bytes, 0, utf8.length)) {
    throw image_ai::Error("invalid_arguments", "Strings must be valid UTF-8 without embedded NUL characters.");
  }
  return std::string(static_cast<const char*>(utf8.bytes), utf8.length);
}
double Number(NSDictionary* args, NSString* key, double fallback) {
  id value = args[key];
  if (!value) return fallback;
  if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    throw image_ai::Error("invalid_arguments", std::string(key.UTF8String) + " must be a number.");
  }
  return [value doubleValue];
}
bool BoolArgument(NSDictionary* args, NSString* key, bool fallback = false) {
  id value = args[key];
  if (!value) return fallback;
  if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
    throw image_ai::Error("invalid_arguments", std::string(key.UTF8String) + " must be a boolean.");
  }
  return [value boolValue];
}
FlutterError* Failure(const char* code, const char* message) {
  return [FlutterError errorWithCode:Text(code) message:Text(message) details:nil];
}


struct ModelAccess {
  NSURL* __strong url = nil;
  bool scoped = false;
  explicit ModelAccess(const std::string& path) {
    if (path.empty()) return;
    NSString* file = Text(path);
    if (![file isAbsolutePath]) throw image_ai::Error("invalid_arguments", "modelPath must be an absolute local file path.");
    url = [NSURL fileURLWithPath:file];
    scoped = [url startAccessingSecurityScopedResource];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:file]) {
      if (scoped) [url stopAccessingSecurityScopedResource];
      scoped = false;
      throw image_ai::Error("model_unavailable", "Model is missing or outside the app's sandbox permission; import it again.");
    }
  }
  ~ModelAccess() { if (scoped) [url stopAccessingSecurityScopedResource]; }
};

struct Worker {
  std::mutex mutex;
  std::shared_ptr<image_ai::Engine> engine;
  std::atomic<uint64_t> generation{0};
  void Cancel() {
    ++generation;
    std::lock_guard<std::mutex> lock(mutex);
    if (engine) engine->Cancel();
  }
  void Release() {
    std::shared_ptr<image_ai::Engine> old;
    {
      std::lock_guard<std::mutex> lock(mutex);
      old.swap(engine);
    }
    // Destruction, including large model allocations, stays off the main thread.
  }
  std::shared_ptr<image_ai::Engine> Get(uint64_t expected) {
    std::lock_guard<std::mutex> lock(mutex);
    if (generation != expected) throw image_ai::Error("cancelled", "Image AI processing was cancelled.");
    if (!engine) engine = std::make_shared<image_ai::Engine>();
    return engine;
  }
};
struct Job {
  image_ai::Request request;
  NSData* __strong bytes = nil;
};
}  // namespace

@interface VeneraImageAIPlugin () {
  dispatch_queue_t _queue;
  std::shared_ptr<Worker> _worker;
  NSMutableDictionary<NSNumber*, FlutterResult>* _pending;
  NSUInteger _pendingBytes;
  uint64_t _nextId;
  BOOL _closed;
  BOOL _background;
}
@end

@implementation VeneraImageAIPlugin
+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  VeneraImageAIPlugin* plugin = [[VeneraImageAIPlugin alloc] init];
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"com.github.kiastr.venera_ssr/colorize"
      binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:plugin channel:channel];
  [registrar publish:plugin];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _worker = std::make_shared<Worker>();
    _pending = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("com.github.kiastr.venera_ssr.image-ai", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
#if TARGET_OS_IOS
    NSNotificationCenter* notifications = [NSNotificationCenter defaultCenter];
    [notifications addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [notifications addObserver:self selector:@selector(enteredBackground:) name:UISceneDidEnterBackgroundNotification object:nil];
    [notifications addObserver:self selector:@selector(enteredForeground:) name:UISceneWillEnterForegroundNotification object:nil];
    [notifications addObserver:self selector:@selector(terminating:) name:UIApplicationWillTerminateNotification object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(terminating:) name:NSApplicationWillTerminateNotification object:nil];
#endif
  }
  return self;
}

- (void)invalidateWork {
  _worker->Cancel();
  auto worker = _worker;
  dispatch_async(_queue, ^{ worker->Release(); });
}

- (void)memoryWarning:(NSNotification*)notification { [self invalidateWork]; }
- (void)enteredBackground:(NSNotification*)notification {
  _background = YES;
  [self invalidateWork];
}
- (void)enteredForeground:(NSNotification*)notification { _background = NO; }
- (void)terminating:(NSNotification*)notification { [self close]; }

- (void)close {
  if (_closed) return;
  _closed = YES;
  [self invalidateWork];
  NSArray* results = _pending.allValues;
  [_pending removeAllObjects];
  _pendingBytes = 0;
  for (FlutterResult result in results) result(Failure("cancelled", "Image AI engine was detached."));
}

#if TARGET_OS_IOS
- (void)detachFromEngineForRegistrar:(id<FlutterPluginRegistrar>)registrar { [self close]; }
#endif

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _worker->Cancel();
  auto worker = _worker;
  dispatch_async(_queue, ^{ worker->Release(); });
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* method = call.method;
  if (![@[@"getCapabilities", @"getModelInfo", @"colorize", @"resetSession"] containsObject:method]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  try {
    if (_closed || _background) throw image_ai::Error("cancelled", "Image AI is unavailable while the app is detached or in the background.");
    if (_pending.count >= kMaxPending) throw image_ai::Error("queue_full", "Image AI queue is full; wait for the current pages to finish.");
    id arguments = call.arguments;
    if (arguments && arguments != [NSNull null] && ![arguments isKindOfClass:[NSDictionary class]]) {
      throw image_ai::Error("invalid_arguments", "Image AI arguments must be a map.");
    }
    NSDictionary* args = [arguments isKindOfClass:[NSDictionary class]] ? arguments : @{};
    auto job = std::make_shared<Job>();
    if ([method isEqualToString:@"getModelInfo"] || [method isEqualToString:@"colorize"]) {
      job->request.model_path = String(args, @"modelPath");
      job->request.type = String(args, @"type");
    } else if ([method isEqualToString:@"resetSession"]) {
      job->request.model_path = String(args, @"modelPath", false);
    }
    if ([method isEqualToString:@"colorize"]) {
      id typed = args[@"imageBytes"];
      if (![typed isKindOfClass:[FlutterStandardTypedData class]] ||
          [(FlutterStandardTypedData*)typed type] != FlutterStandardDataTypeUInt8) {
        throw image_ai::Error("invalid_arguments", "imageBytes must be Uint8List encoded image data.");
      }
      job->bytes = [(FlutterStandardTypedData*)typed data];
      if (!job->bytes.length) {
        throw image_ai::Error("invalid_arguments", "imageBytes must contain encoded image data.");
      }
      const auto budget = image_ai::ImageMemoryBudget() / 4;
      if (job->bytes.length > budget || _pendingBytes > budget - job->bytes.length) {
        throw image_ai::Error("memory_limit", "Pending encoded images exceed available image memory.");
      }
      job->request.model_id = String(args, @"modelId");
      job->request.input_id = String(args, @"inputId");
      job->request.backend = String(args, @"backend", false, "auto");
      job->request.intensity = Number(args, @"intensity", 1);
      job->request.strength = Number(args, @"strength", 1);
      job->request.output_scale = Number(args, @"outputScale", 0);
      job->request.force_reprocess = BoolArgument(args, @"forceReprocess");
    }
    const NSUInteger bytes = job->bytes.length;
    const uint64_t generation = _worker->generation;
    NSNumber* identifier = @(++_nextId);
    _pending[identifier] = [result copy];
    _pendingBytes += bytes;
    auto worker = _worker;
    __weak VeneraImageAIPlugin* weakSelf = self;
    dispatch_async(_queue, ^{
      @autoreleasepool {
        id reply = nil;
        try {
          auto engine = worker->Get(generation);
          if ([method isEqualToString:@"getCapabilities"]) {
            const auto caps = engine->GetCapabilities();
            reply = @{@"supported": @(caps.supported), @"types": Strings(caps.types),
                      @"backends": Strings(caps.backends), @"reason": OptionalText(caps.reason),
                      @"device": caps.supported ? Text(image_ai::AppleMetalDeviceName()) : [NSNull null]};
          } else if ([method isEqualToString:@"resetSession"]) {
            // Reset must also work after the model file was removed.
            engine->Reset(job->request.model_path);
          } else {
            ModelAccess access(job->request.model_path);
            if ([method isEqualToString:@"getModelInfo"]) {
              const auto info = engine->GetModelInfo(job->request.model_path, job->request.type);
              reply = @{@"channels": @(info.channels), @"scale": @(info.scale),
                        @"inputWidth": @(info.input_width), @"inputHeight": @(info.input_height)};
            } else {
              const auto* begin = static_cast<const uint8_t*>(job->bytes.bytes);
              job->request.image_bytes.assign(begin, begin + job->bytes.length);
              job->bytes = nil;
              auto output = std::make_shared<image_ai::Result>(engine->Process(job->request));
              // NSData owns the result vector without another encoded-image copy.
              NSData* encoded = [[NSData alloc] initWithBytesNoCopy:output->image_bytes.data()
                  length:output->image_bytes.size() deallocator:^(void*, NSUInteger) { (void)output; }];
              reply = @{@"imageBytes": [FlutterStandardTypedData typedDataWithBytes:encoded],
                        @"backend": Text(output->backend), @"scale": @(output->scale),
                        @"cacheHit": @(output->cache_hit), @"fallbackReason": OptionalText(output->fallback_reason),
                        @"device": Text(image_ai::AppleMetalDeviceName())};
            }
          }
        } catch (const image_ai::Error& error) {
          reply = Failure(error.code.c_str(), error.what());
        } catch (const std::bad_alloc&) {
          reply = Failure("memory_limit", "Native image processing ran out of memory; use a smaller image or model.");
        } catch (const std::exception& error) {
          reply = Failure("image_ai_failed", error.what());
        } catch (...) {
          reply = Failure("image_ai_failed", "Unknown native image processing failure.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          VeneraImageAIPlugin* plugin = weakSelf;
          if (!plugin) return;
          FlutterResult completion = plugin->_pending[identifier];
          if (!completion) return;
          [plugin->_pending removeObjectForKey:identifier];
          plugin->_pendingBytes -= bytes;
          completion(worker->generation == generation ? reply : Failure("cancelled", "Image AI processing was cancelled."));
        });
      }
    });
  } catch (const image_ai::Error& error) {
    result(Failure(error.code.c_str(), error.what()));
  } catch (const std::exception& error) {
    result(Failure("image_ai_failed", error.what()));
  }
}
@end
