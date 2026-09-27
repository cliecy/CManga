include_guard(GLOBAL)

# ONNX Runtime 1.30.0 core (CPU) plus the official WebGPU plugin execution
# provider (v0.3.0). The plugin targets Dawn's Vulkan backend, so any Vulkan
# driver (NVIDIA or AMD) accelerates inference; the system only needs the GPU
# driver and the Vulkan loader, never a vendor SDK.
# OpenCV is built from the same pinned source as the Windows build.
if(NOT COMMAND cmanga_ai_package)
  function(cmanga_ai_package NAME URL SHA256 OUT_DIR)
    set(ARCHIVE "${CMANGA_AI_DOWNLOAD_CACHE}/${NAME}.zip")
    set(DEST "${CMAKE_BINARY_DIR}/_deps/${NAME}")
    file(MAKE_DIRECTORY "${CMANGA_AI_DOWNLOAD_CACHE}")
    if(EXISTS "${ARCHIVE}")
      file(SHA256 "${ARCHIVE}" ACTUAL_HASH)
      if(NOT ACTUAL_HASH STREQUAL SHA256)
        message(FATAL_ERROR "AI dependency checksum mismatch: ${ARCHIVE}")
      endif()
    else()
      file(DOWNLOAD "${URL}" "${ARCHIVE}.part"
        EXPECTED_HASH "SHA256=${SHA256}" TLS_VERIFY ON STATUS DOWNLOAD_STATUS
        SHOW_PROGRESS)
      list(GET DOWNLOAD_STATUS 0 DOWNLOAD_CODE)
      if(NOT DOWNLOAD_CODE EQUAL 0)
        file(REMOVE "${ARCHIVE}.part")
        message(FATAL_ERROR "Could not download ${NAME}: ${DOWNLOAD_STATUS}")
      endif()
      file(RENAME "${ARCHIVE}.part" "${ARCHIVE}")
    endif()
    if(NOT EXISTS "${DEST}/.extracted-${SHA256}")
      file(REMOVE_RECURSE "${DEST}")
      file(MAKE_DIRECTORY "${DEST}")
      if(URL MATCHES "\\.(nupkg|zip)$")
        # NuGet packages are zip archives; cmake -E tar cannot read them.
        find_package(Python3 REQUIRED COMPONENTS Interpreter)
        execute_process(COMMAND "${Python3_EXECUTABLE}" -m zipfile -e "${ARCHIVE}" "${DEST}"
          RESULT_VARIABLE EXTRACT_RESULT)
      else()
        execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${ARCHIVE}"
          WORKING_DIRECTORY "${DEST}" RESULT_VARIABLE EXTRACT_RESULT)
      endif()
      if(NOT EXTRACT_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not extract verified AI dependency ${NAME}")
      endif()
      file(WRITE "${DEST}/.extracted-${SHA256}" "${SHA256}\n")
    endif()
    set(${OUT_DIR} "${DEST}" PARENT_SCOPE)
  endfunction()
endif()

set(CMANGA_AI_DOWNLOAD_CACHE "$ENV{CMANGA_AI_DOWNLOAD_CACHE}" CACHE PATH
  "Directory containing verified AI dependency archives (also usable offline)")
if(NOT CMANGA_AI_DOWNLOAD_CACHE)
  set(CMANGA_AI_DOWNLOAD_CACHE "${CMAKE_BINARY_DIR}/_deps/downloads")
endif()

if(CMAKE_SIZEOF_VOID_P EQUAL 8 AND
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64)$")
  set(CMANGA_AI_ARCH x64)
else()
  message(FATAL_ERROR "Linux image AI supports only x86_64 targets")
endif()

cmanga_ai_package(ort-core-1.30.0
  "https://github.com/microsoft/onnxruntime/releases/download/v1.30.0/onnxruntime-linux-x64-1.30.0.tgz"
  a5ed5a3cac51fbb2e90da632ae43d19212faaa20e76484e62bcb7c23ddb3b3fd CMANGA_ORT_PKG)
set(CMANGA_ORT_GPU "${CMANGA_ORT_PKG}/onnxruntime-linux-x64-1.30.0")
if(NOT EXISTS "${CMANGA_ORT_GPU}/include/onnxruntime_c_api.h" OR
   NOT EXISTS "${CMANGA_ORT_GPU}/lib/libonnxruntime.so")
  message(FATAL_ERROR "Pinned ONNX Runtime package does not contain the core runtime")
endif()
cmanga_ai_package(ort-ep-webgpu-0.3.0
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.ep.webgpu/0.3.0/microsoft.ml.onnxruntime.ep.webgpu.0.3.0.nupkg"
  8c96476bf982b405bc9192fcf886e7b5b7e7398090df483edf07090bf58583c3 CMANGA_EP_PKG)
if(NOT EXISTS "${CMANGA_EP_PKG}/runtimes/linux-x64/native/libonnxruntime_providers_webgpu.so")
  message(FATAL_ERROR "Pinned WebGPU plugin package does not contain the linux-x64 runtime")
endif()
# The engine resolves the plugin next to the ONNX Runtime core library.
if(NOT EXISTS "${CMANGA_ORT_GPU}/lib/libonnxruntime_providers_webgpu.so")
  file(COPY "${CMANGA_EP_PKG}/runtimes/linux-x64/native/libonnxruntime_providers_webgpu.so"
    DESTINATION "${CMANGA_ORT_GPU}/lib/")
endif()
cmanga_ai_package(opencv-4.11.0
  "https://codeload.github.com/opencv/opencv/zip/refs/tags/4.11.0"
  11dbd2c8d248fa97ac7d20f33c4bab8559ef32835d1c9274009150bb2cf5218a CMANGA_OPENCV)

# Keep OpenCV's options scoped: bundled codecs eliminate host-installed codec
# library dependencies, and the static build links into the app bundle.
function(cmanga_add_opencv)
  set(SAVED_EXECUTABLE_OUTPUT_PATH "${EXECUTABLE_OUTPUT_PATH}")
  # OpenCV's non-FORCE cache assignment does not repair a previously restored
  # empty value. Give its subdirectory a local output path on every configure.
  set(EXECUTABLE_OUTPUT_PATH "${CMAKE_BINARY_DIR}/_deps/opencv-build/bin")
  set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/_deps/opencv-install")
  set(OPENCV_CONFIG_FILE_INCLUDE_DIR "${CMAKE_BINARY_DIR}/_deps/opencv-build"
    CACHE PATH "" FORCE)
  set(BUILD_LIST core,imgproc,imgcodecs CACHE STRING "" FORCE)
  set(BUILD_SHARED_LIBS OFF)
  foreach(OPTION BUILD_TESTS BUILD_PERF_TESTS BUILD_EXAMPLES BUILD_opencv_apps
      BUILD_JAVA BUILD_opencv_python2 BUILD_opencv_python3 BUILD_DOCS
      WITH_OPENCL WITH_OPENEXR WITH_TIFF WITH_JASPER WITH_JPEG2000
      WITH_OPENJPEG WITH_AVIF WITH_GDAL WITH_GDCM WITH_FFMPEG
      WITH_ITT WITH_LAPACK WITH_EIGEN WITH_OBSENSOR WITH_GSTREAMER WITH_TBB WITH_OPENMP
      OPENCV_ENABLE_NONFREE OPENCV_GENERATE_PKGCONFIG)
    set(${OPTION} OFF CACHE BOOL "" FORCE)
  endforeach()
  foreach(OPTION WITH_PNG WITH_JPEG WITH_WEBP BUILD_PNG BUILD_JPEG BUILD_WEBP BUILD_ZLIB)
    set(${OPTION} ON CACHE BOOL "" FORCE)
  endforeach()
  set(OPENCV_FORCE_3RDPARTY_BUILD ON CACHE BOOL "" FORCE)
  set(CPU_DISPATCH "" CACHE STRING "" FORCE)
  add_subdirectory("${CMANGA_OPENCV}/opencv-4.11.0"
    "${CMAKE_BINARY_DIR}/_deps/opencv-build" EXCLUDE_FROM_ALL)
  set(EXECUTABLE_OUTPUT_PATH "${SAVED_EXECUTABLE_OUTPUT_PATH}" CACHE PATH "" FORCE)
endfunction()
cmanga_add_opencv()

function(cmanga_ai_stage_runtime TARGET)
  add_custom_command(TARGET ${TARGET} POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMANGA_ORT_GPU}/lib/libonnxruntime.so.1.30.0" "$<TARGET_FILE_DIR:${TARGET}>/libonnxruntime.so.1"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMANGA_ORT_GPU}/lib/libonnxruntime_providers_shared.so"
      "${CMANGA_ORT_GPU}/lib/libonnxruntime_providers_webgpu.so"
      "$<TARGET_FILE_DIR:${TARGET}>"
    COMMAND_EXPAND_LISTS VERBATIM)
endfunction()
