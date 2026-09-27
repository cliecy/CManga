include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/ImageAiDependencies.cmake")
set(CMANGA_AI_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../native/image_ai")

add_library(cmanga_image_ai STATIC "${CMANGA_AI_SOURCE_DIR}/engine.cpp"
  "${CMANGA_AI_SOURCE_DIR}/image_memory.cpp")
target_compile_features(cmanga_image_ai PUBLIC cxx_std_17)
target_compile_options(cmanga_image_ai PRIVATE /EHsc /W4 /utf-8)
target_compile_definitions(cmanga_image_ai PRIVATE _HAS_EXCEPTIONS=1
  NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_include_directories(cmanga_image_ai PUBLIC "${CMANGA_AI_SOURCE_DIR}")
target_include_directories(cmanga_image_ai SYSTEM PRIVATE
  "${CMANGA_ORT_DML}/build/native/include"
  "${CMANGA_DIRECTML}/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgproc/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
# ORT and DirectML are intentionally NOT linked: each runtime is loaded from an
# explicit bundle path so missing optional DirectML cannot prevent CPU startup.
target_link_libraries(cmanga_image_ai PRIVATE opencv_core opencv_imgproc
  opencv_imgcodecs d3d12 dxgi windowscodecs ole32)

add_executable(cmanga_image_ai_smoke EXCLUDE_FROM_ALL
  "${CMANGA_AI_SOURCE_DIR}/smoke.cpp")
set_target_properties(cmanga_image_ai_smoke PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>")
target_compile_features(cmanga_image_ai_smoke PRIVATE cxx_std_17)
target_compile_options(cmanga_image_ai_smoke PRIVATE /EHsc /utf-8)
target_compile_definitions(cmanga_image_ai_smoke PRIVATE _HAS_EXCEPTIONS=1 NOMINMAX)
target_include_directories(cmanga_image_ai_smoke SYSTEM PRIVATE
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${CMANGA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
target_link_libraries(cmanga_image_ai_smoke PRIVATE cmanga_image_ai)
cmanga_ai_stage_runtime(cmanga_image_ai_smoke)
