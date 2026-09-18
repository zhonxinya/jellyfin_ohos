# Copyright (c) 2026 zhonxinya
# Jellyfin HMOS native shared library (NAPI)

cmake_minimum_required(VERSION 3.16.0)
project(jellyfin_native)

# cpp -> main -> src -> entry -> app -> native
set(NATIVEROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../..")

set(NAPI_ROOT "${NATIVEROOT}/napi")
set(CORE_ROOT "${NATIVEROOT}/core")
# 播放能力放在 feature/ 下，便于整目录移植到其它工程（见 feature/player/README.md）
set(PLAYER_ROOT "${NATIVEROOT}/feature/player")
set(THIRD_PARTY_ROOT "${NATIVEROOT}/third_party")

file(GLOB NAPI_SOURCES CONFIGURE_DEPENDS
  "${NAPI_ROOT}/*.cpp"
)
file(GLOB_RECURSE CORE_SOURCES CONFIGURE_DEPENDS
  "${CORE_ROOT}/*.cpp"
)
# Host-side unit tests must not link into the HAP shared library.
list(FILTER CORE_SOURCES EXCLUDE REGEX "[\\/]tests[\\/]")

file(GLOB_RECURSE PLAYER_SOURCES CONFIGURE_DEPENDS
  "${PLAYER_ROOT}/*.cpp"
)

set(MBEDTLS_DIR "${THIRD_PARTY_ROOT}/mbedtls")
file(GLOB MBEDTLS_SOURCES CONFIGURE_DEPENDS "${MBEDTLS_DIR}/library/*.c")

add_library(jellyfin_native SHARED
  napi_init.cpp
  ${NAPI_SOURCES}
  ${CORE_SOURCES}
  ${PLAYER_SOURCES}
  ${MBEDTLS_SOURCES}
)

target_compile_features(jellyfin_native PRIVATE cxx_std_17)

target_compile_definitions(jellyfin_native PRIVATE
  MBEDTLS_CONFIG_FILE="jellyfin_mbedtls_config.h"
)

target_include_directories(jellyfin_native PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${NAPI_ROOT}
  ${CORE_ROOT}
  ${CORE_ROOT}/api
  ${PLAYER_ROOT}
  ${THIRD_PARTY_ROOT}
  ${THIRD_PARTY_ROOT}/nlohmann
  ${THIRD_PARTY_ROOT}/mbedtls/include
  ${THIRD_PARTY_ROOT}/mbedtls_config
)

# POSIX sockets / threads (HarmonyOS NDK). Avoid Winsock.
find_library(PTHREAD_LIB pthread)
if(PTHREAD_LIB)
  target_link_libraries(jellyfin_native PUBLIC ${PTHREAD_LIB})
endif()

target_link_libraries(jellyfin_native PUBLIC
  libace_napi.z.so
  libhilog_ndk.z.so
  # 官方 XComponent 原生接口（OH_NativeXComponent_*）：EGL/GLES 渲染到 XComponent 的官方入口
  libace_ndk.z.so
)

# 软解渲染：EGL + GLES3 把解码帧直接画进 XComponent surface；
# native_window 用于从 surfaceId 创建 EGLNativeWindowType。
target_link_libraries(jellyfin_native PUBLIC
  EGL
  GLESv3
  native_window
  native_image
)

# ── FFmpeg 软解码（预编译库已入库，构建期仅在失效时重编译）─────────────────────
# FFmpeg 7.1 的**源码随仓库提交**在 native/third_party/ffmpeg/source/，
# **编译好的共享库也随仓库提交**在 native/app/entry/libs/{x86_64,arm64-v8a}/，
# 因此克隆后构建应用直接链接既有产物，不需要用 HarmonyOS 工具链重新编译 FFmpeg。
# 只有产物缺失、或指纹（内置源码树 / 构建脚本）失效时，这里才会自动调用
# scripts/build_ffmpeg_ohos.sh 从内置源码交叉编译（首次约数分钟）；
# 指纹机制与"刷新产物后如何处理 git 变更"见 native/third_party/README.md。
#
# 查找已编译库的顺序：
#   1) 模块内目录  native/app/entry/libs/<abi>/   （随仓库提交；hvigor 会打进 HAP）
#   2) JELLYFIN_FFMPEG_ROOT/<abi>/lib             （默认 <repo 父目录>/_ffmpeg-build/out）
# 仍找不到时**不**定义 JELLYFIN_HAS_FFMPEG：FfmpegDecoder 会如实报告"解码不可用"，
# 而不是假装可用（见 native/feature/player/ffmpeg_decoder.cpp）。
set(JELLYFIN_FFMPEG_ROOT "" CACHE PATH "FFmpeg 预编译根目录（含 <abi>/lib、<abi>/include）")
if(NOT JELLYFIN_FFMPEG_ROOT)
  set(JELLYFIN_FFMPEG_ROOT "${NATIVEROOT}/../../_ffmpeg-build/out")
endif()
option(JELLYFIN_FFMPEG_AUTOBUILD "未找到 FFmpeg 库时从内置源码自动编译" ON)

set(FFMPEG_ABI_DIR "${JELLYFIN_FFMPEG_ROOT}/${OHOS_ARCH}")
# cpp -> main -> src -> entry（本文件位于 <entry>/src/main/cpp）
set(FFMPEG_LOCAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")

# 按当前磁盘状态解析可用库目录（自动编译前后各调用一次）
function(jellyfin_resolve_ffmpeg out_var)
  if(EXISTS "${FFMPEG_LOCAL_DIR}/libavcodec.so")
    set(${out_var} "${FFMPEG_LOCAL_DIR}" PARENT_SCOPE)
  elseif(EXISTS "${FFMPEG_ABI_DIR}/lib/libavcodec.so")
    set(${out_var} "${FFMPEG_ABI_DIR}/lib" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

jellyfin_resolve_ffmpeg(FFMPEG_LINK_DIR)

if(NOT FFMPEG_LINK_DIR AND JELLYFIN_FFMPEG_AUTOBUILD)
  set(FFMPEG_SOURCE_DIR "${THIRD_PARTY_ROOT}/ffmpeg/source")
  set(FFMPEG_BUILD_SCRIPT "${NATIVEROOT}/../scripts/build_ffmpeg_ohos.sh")
  if(EXISTS "${FFMPEG_SOURCE_DIR}/configure" AND EXISTS "${FFMPEG_BUILD_SCRIPT}")
    message(STATUS "FFmpeg：尚未编译，正从内置源码编译（ABI=${OHOS_ARCH}，首次较慢）...")
    execute_process(
      COMMAND bash "${FFMPEG_BUILD_SCRIPT}" "${OHOS_ARCH}"
      WORKING_DIRECTORY "${NATIVEROOT}/.."
      RESULT_VARIABLE FFMPEG_AUTOBUILD_RESULT
      OUTPUT_VARIABLE FFMPEG_AUTOBUILD_LOG
      ERROR_VARIABLE FFMPEG_AUTOBUILD_LOG
    )
    if(NOT FFMPEG_AUTOBUILD_RESULT EQUAL 0)
      message(WARNING "FFmpeg 自动编译失败（退出码 ${FFMPEG_AUTOBUILD_RESULT}）：\n${FFMPEG_AUTOBUILD_LOG}")
      message(WARNING "可手工执行：bash scripts/build_ffmpeg_ohos.sh ${OHOS_ARCH}")
    endif()
    jellyfin_resolve_ffmpeg(FFMPEG_LINK_DIR)
  else()
    message(STATUS "FFmpeg：未找到内置源码（${FFMPEG_SOURCE_DIR}）或构建脚本，跳过自动编译")
  endif()
endif()

if(FFMPEG_LINK_DIR)
  target_compile_definitions(jellyfin_native PRIVATE JELLYFIN_HAS_FFMPEG=1)
  # 头文件优先用仓库内 third_party/ffmpeg/include（随仓库提交，副本/CI 构建均可相对定位），
  # 其次回退到预编译目录 <root>/<abi>/include
  target_include_directories(jellyfin_native PRIVATE
    "${THIRD_PARTY_ROOT}/ffmpeg/include"
    "${FFMPEG_ABI_DIR}/include"
  )
  foreach(FF_LIB avformat avcodec avutil swscale swresample)
    add_library(ff_${FF_LIB} SHARED IMPORTED)
    set_target_properties(ff_${FF_LIB} PROPERTIES
      IMPORTED_LOCATION "${FFMPEG_LINK_DIR}/lib${FF_LIB}.so"
    )
    target_link_libraries(jellyfin_native PUBLIC ff_${FF_LIB})
  endforeach()
  message(STATUS "FFmpeg 软解码：已链接（${FFMPEG_LINK_DIR}，ABI=${OHOS_ARCH}）")
else()
  message(STATUS "FFmpeg 软解码：未找到 ABI=${OHOS_ARCH} 的预编译库，本次构建不启用"
                 "（可运行 scripts/build_ffmpeg_ohos.sh ${OHOS_ARCH}）")
endif()
