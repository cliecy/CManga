#include "image_memory.h"

#include "engine.h"

#include <algorithm>
#include <cstring>
#include <limits>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <ImageIO/ImageIO.h>
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
#include <os/proc.h>
#endif
#endif

namespace image_ai {
namespace {
constexpr uint64_t kMiB = 1024u * 1024u;

uint64_t Add(uint64_t left, uint64_t right) {
  if (right > std::numeric_limits<uint64_t>::max() - left) {
    throw Error("image_too_large", "Image working-set size overflows the supported address space.");
  }
  return left + right;
}

uint64_t Multiply(uint64_t value, uint64_t factor) {
  if (factor && value > std::numeric_limits<uint64_t>::max() / factor) {
    throw Error("image_too_large", "Image working-set size overflows the supported address space.");
  }
  return value * factor;
}
}  // namespace

uint64_t ImageMemoryBudget() {
  uint64_t available = 0;
  uint64_t physical = 0;
  uint64_t minimum_reserve = 256 * kMiB;
#ifdef _WIN32
  MEMORYSTATUSEX status{};
  status.dwLength = sizeof(status);
  if (!GlobalMemoryStatusEx(&status)) return 0;
  physical = status.ullTotalPhys;
  // RAM alone is insufficient if process address space or system commit is full.
  available = std::min({status.ullAvailPhys, status.ullAvailVirtual, status.ullAvailPageFile});
#elif defined(__APPLE__)
  size_t length = sizeof(physical);
  if (sysctlbyname("hw.memsize", &physical, &length, nullptr, 0) != 0 || !physical) return 0;
  const mach_port_t host = mach_host_self();
  vm_size_t page_size = 0;
  vm_statistics64_data_t statistics{};
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  const bool queried = host_page_size(host, &page_size) == KERN_SUCCESS &&
      host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&statistics),
                        &count) == KERN_SUCCESS;
  mach_port_deallocate(mach_task_self(), host);
  if (!queried || !page_size) return 0;
  // Inactive pages are reclaimable; do not double-count speculative/purgeable
  // pages or count compressed memory and swap as immediately available RAM.
  const uint64_t pages = static_cast<uint64_t>(statistics.free_count) + statistics.inactive_count;
  if (pages > std::numeric_limits<uint64_t>::max() / page_size) return 0;
  available = std::min(physical, pages * page_size);
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
  // The simulator has no jetsam process limit and must never call this API.
  available = std::min(available, static_cast<uint64_t>(os_proc_available_memory()));
  minimum_reserve = 128 * kMiB;
#endif
#else
  // An unknown platform/query failure is not permission for unbounded images.
  return 0;
#endif
  // Limit a single request to half physical RAM, even on an otherwise idle host.
  // Live availability already accounts for existing models, caches and GPU use.
  available = std::min(available, physical / 2);
  const uint64_t reserve = std::max(minimum_reserve, available / 4);
  return available > reserve ? available - reserve : 0;
}

void ValidateImageDimensions(int64_t width, int64_t height) {
  // cv::Size::area(), row byte counts and several image codecs use signed int.
  // This is an addressability constraint, separate from resource availability
  // and from tiled model/GPU texture limits (which belong to the provider).
  const uint64_t max_pixels = std::min<uint64_t>(std::numeric_limits<int>::max(),
      std::numeric_limits<size_t>::max() / 64);
  if (width < 1 || height < 1 ||
      static_cast<uint64_t>(width) > static_cast<uint64_t>(std::numeric_limits<int>::max()) / 16 ||
      static_cast<uint64_t>(height) > std::numeric_limits<int>::max() ||
      static_cast<uint64_t>(width) > max_pixels / static_cast<uint64_t>(height)) {
    throw Error("image_too_large", "Image dimensions exceed native image/array addressability limits.");
  }
}

void ValidateImageWorkingSet(uint64_t input_pixels, uint64_t native_pixels,
                             uint64_t output_pixels) {
  // Upper envelope of the actual simultaneously live buffers, not PNG size:
  // input: decoded BGR/alpha, float original/source, linear copy and alpha (40 B);
  // native: inference result plus enhanced/color-conversion, linear and alpha
  //         copies, including one-channel SR reconstruction (64 B);
  // output: both float blend branches, resize temporaries, byte BGRA, PNG growth
  //         and method-channel serialization copies (64 B).
  // The 64 MiB scratch allowance covers codec rows, tile I/O and allocator slack;
  // model weights already live reduce available memory, while the budget's 25%
  // reserve leaves room for model execution. This is a conservative preflight,
  // not a guarantee against another process allocating after the query.
  const uint64_t required = Add(Add(Multiply(input_pixels, 40), Multiply(native_pixels, 64)),
                                Add(Multiply(output_pixels, 64), 64 * kMiB));
  if (required > std::numeric_limits<size_t>::max()) {
    throw Error("image_too_large", "Image working set exceeds native addressability limits.");
  }
  const uint64_t budget = ImageMemoryBudget();
  if (required > budget) {
    throw Error("memory_limit", "Insufficient available memory for the image working set (requires " +
        std::to_string(required / kMiB + (required % kMiB != 0)) + " MiB; budget " +
        std::to_string(budget / kMiB) + " MiB). Choose a smaller image or model scale.");
  }
}

uint64_t ValidateEncodedImage(const uint8_t* bytes, size_t length) {
  if (!bytes || !length) throw Error("invalid_image", "Encoded image is empty.");
  if (length > ImageMemoryBudget() / 4) {
    throw Error("memory_limit", "Encoded image copies exceed available image memory.");
  }
  int64_t width = 0, height = 0;
  // Some Windows installations have no WIC WebP codec, although OpenCV does.
  if (length >= 20 && std::memcmp(bytes, "RIFF", 4) == 0 &&
      std::memcmp(bytes + 8, "WEBP", 4) == 0) {
    auto little = [](const uint8_t* p, int count) {
      uint32_t value = 0;
      for (int i = 0; i < count; ++i) value |= static_cast<uint32_t>(p[i]) << (8 * i);
      return value;
    };
    for (size_t offset = 12; offset <= length - 8;) {
      const uint32_t size = little(bytes + offset + 4, 4);
      if (size > length - offset - 8) break;
      const auto* data = bytes + offset + 8;
      if (std::memcmp(bytes + offset, "VP8X", 4) == 0 && size >= 10) {
        width = little(data + 4, 3) + 1;
        height = little(data + 7, 3) + 1;
      } else if (std::memcmp(bytes + offset, "VP8L", 4) == 0 && size >= 5 && data[0] == 0x2f) {
        const auto bits = little(data + 1, 4);
        width = (bits & 0x3fff) + 1;
        height = ((bits >> 14) & 0x3fff) + 1;
      } else if (std::memcmp(bytes + offset, "VP8 ", 4) == 0 && size >= 10 &&
                 (data[0] & 1) == 0 && data[3] == 0x9d && data[4] == 1 && data[5] == 0x2a) {
        width = little(data + 6, 2) & 0x3fff;
        height = little(data + 8, 2) & 0x3fff;
      }
      if (width && height) break;
      offset += 8 + static_cast<size_t>(size) + (size & 1);
    }
  } else {
#ifdef __APPLE__
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes,
        static_cast<CFIndex>(length), kCFAllocatorNull);
    if (!data) throw Error("memory_limit", "Image header buffer could not be allocated.");
    CGImageSourceRef source = CGImageSourceCreateWithData(data, nullptr);
    CFRelease(data);
    if (!source) throw Error("invalid_image", "Image header could not be decoded.");
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (properties) {
      const auto w = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
      const auto h = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
      if (w && CFGetTypeID(w) == CFNumberGetTypeID())
        CFNumberGetValue(static_cast<CFNumberRef>(w), kCFNumberSInt64Type, &width);
      if (h && CFGetTypeID(h) == CFNumberGetTypeID())
        CFNumberGetValue(static_cast<CFNumberRef>(h), kCFNumberSInt64Type, &height);
      CFRelease(properties);
    }
#elif defined(_WIN32)
    if (length > std::numeric_limits<DWORD>::max()) {
      throw Error("image_too_large", "Encoded image exceeds the decoder addressable range.");
    }
    struct ComScope {
      HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      ~ComScope() { if (SUCCEEDED(result)) CoUninitialize(); }
    } com;
    Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
    Microsoft::WRL::ComPtr<IWICStream> stream;
    Microsoft::WRL::ComPtr<IWICBitmapDecoder> decoder;
    Microsoft::WRL::ComPtr<IWICBitmapFrameDecode> frame;
    UINT w = 0, h = 0;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(factory.GetAddressOf()))) ||
        FAILED(factory->CreateStream(stream.GetAddressOf())) ||
        FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(bytes), static_cast<DWORD>(length))) ||
        FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand,
            decoder.GetAddressOf())) ||
        FAILED(decoder->GetFrame(0, frame.GetAddressOf())) ||
        FAILED(frame->GetSize(&w, &h))) {
      throw Error("invalid_image", "Image header could not be safely decoded.");
    }
    width = w;
    height = h;
#endif
  }
  if (width < 1 || height < 1) throw Error("invalid_image", "Image dimensions are unavailable.");
  ValidateImageDimensions(width, height);
  const uint64_t pixels = static_cast<uint64_t>(width) * height;
  ValidateImageWorkingSet(pixels, 0, 0);
  return pixels;
}

}  // namespace image_ai
