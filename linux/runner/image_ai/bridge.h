#ifndef CMANGA_IMAGE_AI_BRIDGE_H_
#define CMANGA_IMAGE_AI_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

#include <memory>

namespace image_ai {

// All public calls and destruction are on the Flutter platform thread.
class Bridge {
 public:
  explicit Bridge(FlBinaryMessenger* messenger);
  ~Bridge();
  Bridge(const Bridge&) = delete;
  Bridge& operator=(const Bridge&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace image_ai
#endif
