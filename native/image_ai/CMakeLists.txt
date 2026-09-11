cmake_minimum_required(VERSION 3.22)
project(cmanga_image_ai_smoke LANGUAGES CXX OBJCXX)
if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR "This standalone smoke target is macOS-only; Windows uses windows/cmake/ImageAiTarget.cmake")
endif()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)
get_filename_component(CMANGA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
# Do not find a host ORT: the Homebrew/CocoaPods CPU-only builds cannot satisfy
# the hardware-only Metal contract, even when their headers mention WebGPU.
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMANGA_ROOT}/native/apple/build_ort_metal.py" --platform macos
  RESULT_VARIABLE CMANGA_ORT_BUILD_RESULT
  COMMAND_ERROR_IS_FATAL ANY)
set(ORT_FRAMEWORK "${CMANGA_ROOT}/build/apple-ort/macos/package/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework")
if(NOT EXISTS "${ORT_FRAMEWORK}/onnxruntime")
  message(FATAL_ERROR "The pinned Metal XCFramework was not produced")
endif()
add_library(cmanga_image_ai STATIC engine.cpp image_memory.cpp ../apple/metal_provider.mm)
set_source_files_properties(../apple/metal_provider.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_compile_features(cmanga_image_ai PUBLIC cxx_std_17)
target_include_directories(cmanga_image_ai PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(cmanga_image_ai SYSTEM PRIVATE "${ORT_FRAMEWORK}/Headers" ${OpenCV_INCLUDE_DIRS})
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(IOSURFACE_FRAMEWORK IOSurface REQUIRED)
find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
find_library(NETWORK_FRAMEWORK Network REQUIRED)
target_link_libraries(cmanga_image_ai PRIVATE "${ORT_FRAMEWORK}/onnxruntime" ${OpenCV_LIBS}
  "${FOUNDATION_FRAMEWORK}" "${METAL_FRAMEWORK}" "${QUARTZCORE_FRAMEWORK}"
  "${IOSURFACE_FRAMEWORK}" "${IOKIT_FRAMEWORK}" "${IMAGEIO_FRAMEWORK}" "${NETWORK_FRAMEWORK}")
add_executable(cmanga_image_ai_smoke smoke.cpp)
target_compile_features(cmanga_image_ai_smoke PRIVATE cxx_std_17)
target_include_directories(cmanga_image_ai_smoke SYSTEM PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(cmanga_image_ai_smoke PRIVATE cmanga_image_ai ${OpenCV_LIBS})
