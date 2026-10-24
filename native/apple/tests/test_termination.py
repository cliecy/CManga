#!/usr/bin/env python3
"""Exercise the production Apple plugin's shutdown with a controlled fake engine.

Requires macOS Command Line Tools; no Flutter SDK, model or GPU is needed.
The fake destructor delays release to make the exit race deterministic.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]

FLUTTER = r'''
#import <Cocoa/Cocoa.h>
typedef void (^FlutterResult)(id);
@protocol FlutterPluginRegistrar;
@protocol FlutterPlugin
+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar;
@end
@interface FlutterMethodCall : NSObject
@property(copy) NSString* method;
@property(strong) id arguments;
@end
@interface FlutterMethodChannel : NSObject
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(id)messenger;
@end
@protocol FlutterPluginRegistrar
- (id)messenger;
- (void)addMethodCallDelegate:(id)plugin channel:(id)channel;
- (void)publish:(id)plugin;
@end
@interface FlutterError : NSObject
+ (instancetype)errorWithCode:(NSString*)code message:(NSString*)message details:(id)details;
@end
typedef NS_ENUM(NSUInteger, FlutterStandardDataType) { FlutterStandardDataTypeUInt8 };
@interface FlutterStandardTypedData : NSObject
@property(readonly) FlutterStandardDataType type;
@property(readonly) NSData* data;
+ (instancetype)typedDataWithBytes:(NSData*)bytes;
@end
extern NSObject* FlutterMethodNotImplemented;
'''

TEST = r'''
#include "native/apple/CMangaImageAIPlugin.mm"
#include <cassert>
#include <chrono>
#include <thread>

NSObject* FlutterMethodNotImplemented = nil;
@implementation FlutterMethodCall
@end
@implementation FlutterMethodChannel
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(id)messenger { return [self new]; }
@end
@implementation FlutterError
+ (instancetype)errorWithCode:(NSString*)code message:(NSString*)message details:(id)details { return [self new]; }
@end
@implementation FlutterStandardTypedData
- (FlutterStandardDataType)type { return FlutterStandardDataTypeUInt8; }
- (NSData*)data { return nil; }
+ (instancetype)typedDataWithBytes:(NSData*)bytes { return [self new]; }
@end

static std::atomic<bool> started{false}, cancelled{false}, released{false};
namespace image_ai {
struct Engine::Impl {};
Engine::Engine() = default;
Engine::~Engine() {
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  released = true;
}
Capabilities Engine::GetCapabilities() {
  started = true;
  while (!cancelled) std::this_thread::yield();
  throw Error("cancelled", "Test inference cancelled.");
}
void Engine::Cancel() noexcept { cancelled = true; }
void Engine::Reset(const std::string&) {}
ModelInfo Engine::GetModelInfo(const std::string&, const std::string&) { return {}; }
Result Engine::Process(const Request&) { return {}; }
uint64_t ImageMemoryBudget() { return 1024 * 1024; }
std::string AppleMetalDeviceName() { return "Test device"; }
}

int main(int argc, char** argv) {
  @autoreleasepool {
    CMangaImageAIPlugin* plugin = [CMangaImageAIPlugin new];
    FlutterMethodCall* call = [FlutterMethodCall new];
    call.method = @"getCapabilities";
    __block int completions = 0;
    [plugin handleMethodCall:call result:^(id reply) {
      assert([reply isKindOfClass:[FlutterError class]]);
      ++completions;
    }];
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!started) {
      assert(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }
    if (argc > 1) [plugin close];  // A previous close must not bypass draining.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSApplicationWillTerminateNotification object:nil];
    assert(cancelled);
    assert(released);  // Must finish destruction BEFORE the notification returns.
    assert(completions == 1);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSApplicationWillTerminateNotification object:nil];
    assert(completions == 1);
    [plugin handleMethodCall:call result:^(id reply) {
      assert([reply isKindOfClass:[FlutterError class]]);
      ++completions;
    }];
    assert(completions == 2);
    // Run the previously queued main-thread reply: it must not complete twice.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    assert(completions == 2);
  }
  return 0;
}
'''


class TerminationTest(unittest.TestCase):
    def test_termination_drains_inference_and_release(self):
        with tempfile.TemporaryDirectory(prefix="cmanga-termination-") as tmp:
            tmp = pathlib.Path(tmp)
            headers = tmp / "FlutterMacOS"
            headers.mkdir()
            (headers / "FlutterMacOS.h").write_text(FLUTTER)
            (tmp / "onnxruntime_c_api.h").write_text(
                "typedef struct OrtApi OrtApi;\n"
                "typedef struct OrtSessionOptions OrtSessionOptions;\n"
            )
            source = tmp / "termination.mm"
            source.write_text(TEST)
            binary = tmp / "termination"
            subprocess.run([
                "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
                "-I", str(tmp), "-I", str(ROOT), str(source),
                "-framework", "Cocoa", "-o", str(binary),
            ], check=True)
            for args in ([], ["already-closed"]):
                with self.subTest(args=args):
                    subprocess.run([str(binary), *args], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
