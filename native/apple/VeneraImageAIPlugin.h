#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

NS_ASSUME_NONNULL_BEGIN
@interface VeneraImageAIPlugin : NSObject <FlutterPlugin>
@end
NS_ASSUME_NONNULL_END
