#ifndef CMANGA_IMAGE_AI_IMAGE_MEMORY_H_
#define CMANGA_IMAGE_AI_IMAGE_MEMORY_H_

#include <cstdint>
#include <cstddef>

namespace image_ai {

// Additional image allocation budget from live system/process headroom, after
// reserving memory for the OS, model execution and the rest of the application.
// Returns zero when headroom cannot be established safely. Not a reservation.
uint64_t ImageMemoryBudget();

// Structural OpenCV/array limits only; never a device-independent megapixel cap.
void ValidateImageDimensions(int64_t width, int64_t height);

// Read header dimensions without first allocating the decoded raster.
uint64_t ValidateEncodedImage(const uint8_t* bytes, size_t length);

// Call before decode, inference, and render allocations using current headroom.
// native_pixels == 0 means no new inference result (bypass or cache hit). On a
// cache hit, output_pixels must cover max(native render extent, final extent):
// rendering still materializes native-resolution float/alpha intermediates.
// Input/cache/model allocations already live are reflected in current headroom;
// including the input again intentionally leaves conservative decode slack.
void ValidateImageWorkingSet(uint64_t input_pixels, uint64_t native_pixels,
                             uint64_t output_pixels);

}  // namespace image_ai
#endif
