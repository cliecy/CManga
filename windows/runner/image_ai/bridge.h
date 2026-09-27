#ifndef CMANGA_IMAGE_AI_BRIDGE_H_
#define CMANGA_IMAGE_AI_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>

namespace image_ai {

// All public calls and destruction are on the Flutter platform thread.
class Bridge {
 public:
  static constexpr UINT kCompletionMessage = WM_APP + 0x4a1;
  Bridge(flutter::BinaryMessenger* messenger, HWND window);
  ~Bridge();
  Bridge(const Bridge&) = delete;
  Bridge& operator=(const Bridge&) = delete;
  void DrainReplies();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace image_ai
#endif
