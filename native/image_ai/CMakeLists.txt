cmake_minimum_required(VERSION 3.18)
project(venera_image_ai_smoke LANGUAGES CXX)
if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR "This standalone smoke target is macOS-only; Windows uses windows/cmake/ImageAiTarget.cmake")
endif()

# OpenCV_DIR/CMAKE_PREFIX_PATH and VENERA_ORT_ROOT can select exact dependencies
# instead of host packages. ORT_INCLUDE_DIR/ORT_LIBRARY also accept an extracted
# official CocoaPods framework's Headers and onnxruntime.framework binary.
set(VENERA_ORT_ROOT "" CACHE PATH "ONNX Runtime install or extracted framework root")
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)
find_path(ORT_INCLUDE_DIR onnxruntime_c_api.h
  HINTS "${VENERA_ORT_ROOT}" /opt/homebrew/opt/onnxruntime /usr/local/opt/onnxruntime
  PATH_SUFFIXES include include/onnxruntime include/onnxruntime/core/session Headers)
find_library(ORT_LIBRARY NAMES onnxruntime
  HINTS "${VENERA_ORT_ROOT}" /opt/homebrew/opt/onnxruntime /usr/local/opt/onnxruntime
  PATH_SUFFIXES lib)
if(NOT ORT_INCLUDE_DIR OR NOT ORT_LIBRARY)
  message(FATAL_ERROR "Set VENERA_ORT_ROOT or ORT_INCLUDE_DIR/ORT_LIBRARY to a real ONNX Runtime installation")
endif()
add_library(venera_image_ai STATIC engine.cpp)
target_compile_features(venera_image_ai PUBLIC cxx_std_17)
target_include_directories(venera_image_ai PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(venera_image_ai SYSTEM PRIVATE "${ORT_INCLUDE_DIR}" ${OpenCV_INCLUDE_DIRS})
# Official static ORT Apple archives contain Foundation/CoreML references even
# when the application selects CPU. Dynamic Homebrew builds resolve these inside
# the dylib, but extracted XCFrameworks need the host to link them explicitly.
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(COREML_FRAMEWORK CoreML REQUIRED)
target_link_libraries(venera_image_ai PRIVATE "${ORT_LIBRARY}" ${OpenCV_LIBS}
  "${FOUNDATION_FRAMEWORK}" "${COREML_FRAMEWORK}")
add_executable(venera_image_ai_smoke smoke.cpp)
target_compile_features(venera_image_ai_smoke PRIVATE cxx_std_17)
target_include_directories(venera_image_ai_smoke SYSTEM PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(venera_image_ai_smoke PRIVATE venera_image_ai ${OpenCV_LIBS})
