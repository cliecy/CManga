include_guard(GLOBAL)

# The NuGet manifests contain win-x64 AND win-arm64 native binaries. DirectML
# 1.15.4 is the dependency declared by ONNX Runtime DirectML 1.22.0's nuspec.
# OpenCV is built from the same pinned source for both target architectures.
set(VENERA_AI_DOWNLOAD_CACHE "$ENV{VENERA_AI_DOWNLOAD_CACHE}" CACHE PATH
  "Directory containing verified AI dependency archives (also usable offline)")
if(NOT VENERA_AI_DOWNLOAD_CACHE)
  set(VENERA_AI_DOWNLOAD_CACHE "${CMAKE_BINARY_DIR}/_deps/downloads")
endif()

function(venera_ai_package NAME URL SHA256 OUT_DIR)
  set(ARCHIVE "${VENERA_AI_DOWNLOAD_CACHE}/${NAME}.zip")
  set(DEST "${CMAKE_BINARY_DIR}/_deps/${NAME}")
  file(MAKE_DIRECTORY "${VENERA_AI_DOWNLOAD_CACHE}")
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
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${ARCHIVE}"
      WORKING_DIRECTORY "${DEST}" RESULT_VARIABLE EXTRACT_RESULT)
    if(NOT EXTRACT_RESULT EQUAL 0)
      message(FATAL_ERROR "Could not extract verified AI dependency ${NAME}")
    endif()
    file(WRITE "${DEST}/.extracted-${SHA256}" "${SHA256}\n")
  endif()
  set(${OUT_DIR} "${DEST}" PARENT_SCOPE)
endfunction()

if(CMAKE_GENERATOR_PLATFORM MATCHES "^[Aa][Rr][Mm]64$" OR
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(VENERA_AI_ARCH arm64)
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND
       (CMAKE_GENERATOR_PLATFORM STREQUAL "x64" OR
        CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64)$"))
  set(VENERA_AI_ARCH x64)
else()
  message(FATAL_ERROR "Windows image AI supports only x64 and ARM64 targets")
endif()

venera_ai_package(ort-cpu-1.22.0
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.22.0/microsoft.ml.onnxruntime.1.22.0.nupkg"
  d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a VENERA_ORT_CPU)
venera_ai_package(ort-dml-1.22.0
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.22.0/microsoft.ml.onnxruntime.directml.1.22.0.nupkg"
  29f9872d786236b79aa83f94482f3a17c14297e4833768d6d0ed4883ee732e60 VENERA_ORT_DML)
venera_ai_package(directml-1.15.4
  "https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/1.15.4/microsoft.ai.directml.1.15.4.nupkg"
  4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9 VENERA_DIRECTML)
venera_ai_package(opencv-4.11.0
  "https://codeload.github.com/opencv/opencv/zip/refs/tags/4.11.0"
  11dbd2c8d248fa97ac7d20f33c4bab8559ef32835d1c9274009150bb2cf5218a VENERA_OPENCV)

set(VENERA_AI_CPU_DLLS
  "${VENERA_ORT_CPU}/runtimes/win-${VENERA_AI_ARCH}/native/onnxruntime.dll"
  "${VENERA_ORT_CPU}/runtimes/win-${VENERA_AI_ARCH}/native/onnxruntime_providers_shared.dll")
set(VENERA_AI_DML_DLLS
  "${VENERA_ORT_DML}/runtimes/win-${VENERA_AI_ARCH}/native/onnxruntime.dll"
  "${VENERA_ORT_DML}/runtimes/win-${VENERA_AI_ARCH}/native/onnxruntime_providers_shared.dll"
  "${VENERA_DIRECTML}/bin/${VENERA_AI_ARCH}-win/DirectML.dll")
foreach(DLL IN LISTS VENERA_AI_CPU_DLLS VENERA_AI_DML_DLLS)
  if(NOT EXISTS "${DLL}")
    message(FATAL_ERROR "Pinned AI package does not contain ${DLL}")
  endif()
endforeach()

# Keep OpenCV's options scoped: do not change Flutter/plugin exception or CRT
# policy. Bundled codecs eliminate host-installed codec DLL dependencies.
function(venera_add_opencv)
  set(SAVED_EXECUTABLE_OUTPUT_PATH "${EXECUTABLE_OUTPUT_PATH}")
  # OpenCV's non-FORCE cache assignment does not repair a previously restored
  # empty value. Give its subdirectory a local output path on every configure.
  set(EXECUTABLE_OUTPUT_PATH "${CMAKE_BINARY_DIR}/_deps/opencv-build/bin")
  # Flutter's bundle prefix is a generator expression; OpenCV computes paths
  # during configure and needs a concrete, subproject-local install prefix.
  set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/_deps/opencv-install")
  set(OPENCV_CONFIG_FILE_INCLUDE_DIR "${CMAKE_BINARY_DIR}/_deps/opencv-build"
    CACHE PATH "" FORCE)
  set(BUILD_LIST core,imgproc,imgcodecs CACHE STRING "" FORCE)
  set(BUILD_SHARED_LIBS OFF)
  set(BUILD_WITH_STATIC_CRT OFF CACHE BOOL "" FORCE)
  foreach(OPTION BUILD_TESTS BUILD_PERF_TESTS BUILD_EXAMPLES BUILD_opencv_apps
      BUILD_JAVA BUILD_opencv_python2 BUILD_opencv_python3 BUILD_DOCS
      WITH_IPP WITH_OPENCL WITH_OPENEXR WITH_TIFF WITH_JASPER WITH_JPEG2000
      WITH_OPENJPEG WITH_AVIF WITH_GDAL WITH_GDCM WITH_FFMPEG
      WITH_MSMF WITH_DSHOW WITH_VTK WITH_ITT WITH_LAPACK WITH_EIGEN
      WITH_DIRECTX WITH_DIRECTML WITH_CAROTENE WITH_PROTOBUF WITH_FLATBUFFERS
      WITH_OBSENSOR WITH_GSTREAMER WITH_TBB WITH_OPENMP
      OPENCV_ENABLE_NONFREE OPENCV_GENERATE_PKGCONFIG)
    set(${OPTION} OFF CACHE BOOL "" FORCE)
  endforeach()
  foreach(OPTION WITH_PNG WITH_JPEG WITH_WEBP BUILD_PNG BUILD_JPEG BUILD_WEBP BUILD_ZLIB)
    set(${OPTION} ON CACHE BOOL "" FORCE)
  endforeach()
  set(OPENCV_FORCE_3RDPARTY_BUILD ON CACHE BOOL "" FORCE)
  set(CPU_DISPATCH "" CACHE STRING "" FORCE)
  if(VENERA_AI_ARCH STREQUAL "arm64")
    # Visual Studio cross-builds otherwise report the AMD64 host processor to
    # OpenCV and select x86 codec intrinsics for ARM64 objects.
    set(CMAKE_SYSTEM_PROCESSOR ARM64)
    set(CPU_BASELINE NEON CACHE STRING "" FORCE)
  endif()
  add_subdirectory("${VENERA_OPENCV}/opencv-4.11.0"
    "${CMAKE_BINARY_DIR}/_deps/opencv-build" EXCLUDE_FROM_ALL)
  # OpenCV writes this legacy global cache variable; do not redirect Flutter's
  # runner away from build/windows/<arch>/runner/<configuration>.
  set(EXECUTABLE_OUTPUT_PATH "${SAVED_EXECUTABLE_OUTPUT_PATH}" CACHE PATH "" FORCE)
endfunction()
venera_add_opencv()

function(venera_ai_stage_runtime TARGET)
  add_custom_command(TARGET ${TARGET} POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${VENERA_AI_CPU_DLLS}
      "$<TARGET_FILE_DIR:${TARGET}>"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
      "$<TARGET_FILE_DIR:${TARGET}>/image_ai/directml"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${VENERA_AI_DML_DLLS}
      "$<TARGET_FILE_DIR:${TARGET}>/image_ai/directml"
    COMMAND_EXPAND_LISTS VERBATIM)
endfunction()

function(venera_ai_install_runtime)
  # Flutter uses a generator expression as its bundle prefix. Keep it in the
  # destination itself so CMake resolves it instead of creating a literal path.
  install(FILES ${VENERA_AI_CPU_DLLS} DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
  install(FILES ${VENERA_AI_DML_DLLS} DESTINATION "${CMAKE_INSTALL_PREFIX}/image_ai/directml" COMPONENT Runtime)
  install(FILES "${VENERA_ORT_CPU}/LICENSE" "${VENERA_ORT_CPU}/ThirdPartyNotices.txt"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses/onnxruntime" COMPONENT Runtime)
  install(FILES "${VENERA_DIRECTML}/LICENSE.txt" "${VENERA_DIRECTML}/LICENSE-CODE.txt"
    "${VENERA_DIRECTML}/ThirdPartyNotices.txt"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses/directml" COMPONENT Runtime)
  install(FILES "${VENERA_OPENCV}/opencv-4.11.0/LICENSE"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses/opencv" COMPONENT Runtime)
  install(DIRECTORY "${VENERA_OPENCV}/opencv-4.11.0/3rdparty/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses/opencv/3rdparty" COMPONENT Runtime
    FILES_MATCHING PATTERN "*LICENSE*" PATTERN "*COPYING*" PATTERN "*README*")
endfunction()
