include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/ImageAiDependencies.cmake")
set(CMANGA_AI_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../image_ai")

add_library(cmanga_image_ai STATIC "${CMANGA_AI_SOURCE_DIR}/engine.cpp"
  "${CMANGA_AI_SOURCE_DIR}/image_memory.cpp")
target_compile_features(cmanga_image_ai PUBLIC cxx_std_17)
target_compile_options(cmanga_image_ai PRIVATE -Wall -Werror)
target_include_directories(cmanga_image_ai PUBLIC "${CMANGA_AI_SOURCE_DIR}")
target_include_directories(cmanga_image_ai SYSTEM PRIVATE
  "${CMANGA_ORT_GPU}/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgproc/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
# The WebGPU plugin execution provider is a separate shared library loaded
# at run time; only the GPU driver and the Vulkan loader are needed.
target_link_libraries(cmanga_image_ai PRIVATE
  "${CMANGA_ORT_GPU}/lib/libonnxruntime.so"
  opencv_core opencv_imgproc opencv_imgcodecs
  pthread dl)

add_executable(cmanga_image_ai_smoke EXCLUDE_FROM_ALL
  "${CMANGA_AI_SOURCE_DIR}/smoke.cpp")
set_target_properties(cmanga_image_ai_smoke PROPERTIES BUILD_RPATH "$ORIGIN")
target_compile_features(cmanga_image_ai_smoke PRIVATE cxx_std_17)
target_compile_options(cmanga_image_ai_smoke PRIVATE -Wall -Werror)
target_include_directories(cmanga_image_ai_smoke SYSTEM PRIVATE
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
target_link_libraries(cmanga_image_ai_smoke PRIVATE cmanga_image_ai)
cmanga_ai_stage_runtime(cmanga_image_ai_smoke)
