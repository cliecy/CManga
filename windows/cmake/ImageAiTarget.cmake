include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/ImageAiDependencies.cmake")
set(VENERA_AI_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../native/image_ai")

add_library(venera_image_ai STATIC "${VENERA_AI_SOURCE_DIR}/engine.cpp")
target_compile_features(venera_image_ai PUBLIC cxx_std_17)
target_compile_options(venera_image_ai PRIVATE /EHsc /W4 /utf-8)
target_compile_definitions(venera_image_ai PRIVATE _HAS_EXCEPTIONS=1
  NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_include_directories(venera_image_ai PUBLIC "${VENERA_AI_SOURCE_DIR}")
target_include_directories(venera_image_ai SYSTEM PRIVATE
  "${VENERA_ORT_DML}/build/native/include"
  "${VENERA_DIRECTML}/include"
  "${VENERA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${VENERA_OPENCV}/opencv-4.11.0/modules/imgproc/include"
  "${VENERA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
# ORT and DirectML are intentionally NOT linked: each runtime is loaded from an
# explicit bundle path so missing optional DirectML cannot prevent CPU startup.
target_link_libraries(venera_image_ai PRIVATE opencv_core opencv_imgproc
  opencv_imgcodecs d3d12 dxgi)

add_executable(venera_image_ai_smoke EXCLUDE_FROM_ALL
  "${VENERA_AI_SOURCE_DIR}/smoke.cpp")
set_target_properties(venera_image_ai_smoke PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>")
target_compile_features(venera_image_ai_smoke PRIVATE cxx_std_17)
target_compile_options(venera_image_ai_smoke PRIVATE /EHsc /utf-8)
target_compile_definitions(venera_image_ai_smoke PRIVATE _HAS_EXCEPTIONS=1 NOMINMAX)
target_include_directories(venera_image_ai_smoke SYSTEM PRIVATE
  "${VENERA_OPENCV}/opencv-4.11.0/modules/core/include"
  "${VENERA_OPENCV}/opencv-4.11.0/modules/imgcodecs/include"
  "${CMAKE_BINARY_DIR}/_deps/opencv-build")
target_link_libraries(venera_image_ai_smoke PRIVATE venera_image_ai)
venera_ai_stage_runtime(venera_image_ai_smoke)
