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

# ── 编译警告：只作用于本工程自有源码 ──────────────────────────────────────────
# 此前这里**没有**任何警告开关，于是 HAP 构建即便编出可疑代码也是全静默的。
# 加开关是一条零改动的纯护栏：实测自有源码在 -Wall -Wextra -Wpedantic 下当前
# **0 警告**（含启用 FFmpeg 分支的编译），所以打开它不会掩盖也不会制造噪声。
#
# 为什么不加 -Werror：
#   本工程同时存在 vendored 第三方（mbedTLS/FFmpeg/dav1d/nlohmann）与两套编译器
#   （hvigor 内的 clang、CI 上的 g++），不同版本会各自新增不同警告。一刀切 -Werror
#   的后果是"换工具链版本就构建失败"，而这类失败与代码正确性无关。真要强制，应当
#   在评审与 CI 上按具体警告逐条决定，而不是全局打开。
#
# 为什么用 set_source_files_properties 而不是 target_compile_options：
#   target_compile_options 会连带作用于 vendored 的 mbedTLS（实测其源码在
#   -Wall -Wextra 下自带 2 条警告）。那属于上游风格，不该由本工程"修"，也不该
#   混进构建日志淹没有效信息。按源文件属性设置即可精确圈定自有代码。
set(JELLYFIN_OWN_SOURCES
  napi_init.cpp
  ${NAPI_SOURCES}
  ${CORE_SOURCES}
  ${PLAYER_SOURCES}
)
set_source_files_properties(${JELLYFIN_OWN_SOURCES} PROPERTIES
  COMPILE_OPTIONS "-Wall;-Wextra;-Wpedantic"
)

# ── clang-tidy（可选、默认关闭）───────────────────────────────────────────────
# 仓库里已有一份 `native/app/.clang-tidy`（HarmonyOS 预设 checks），但此前从未接入
# 任何构建，等于摆设。这里提供开关而**不**默认打开：
#   clang-tidy 需要能完整解析该文件的 include（native/feature/player 的部分文件依赖
#   OHOS 的 ACE/EGL 头，在主机与 CI 上都不具备），且会给每次构建增加可观耗时。
#   持续执行交给 CI 的独立 lint 任务（见 .github/workflows/build.yml）。
# 本地想跑：cmake -DJELLYFIN_ENABLE_CLANG_TIDY=ON ...
option(JELLYFIN_ENABLE_CLANG_TIDY "在自有源码上启用 clang-tidy（需自备 clang-tidy）" OFF)
if(JELLYFIN_ENABLE_CLANG_TIDY)
  find_program(JELLYFIN_CLANG_TIDY NAMES clang-tidy)
  if(JELLYFIN_CLANG_TIDY)
    set(CMAKE_CXX_CLANG_TIDY "${JELLYFIN_CLANG_TIDY}")
    message(STATUS "clang-tidy 已启用：${JELLYFIN_CLANG_TIDY}")
  else()
    message(WARNING "JELLYFIN_ENABLE_CLANG_TIDY=ON 但找不到 clang-tidy，已跳过")
  endif()
endif()

# ── 版本号单一来源 ────────────────────────────────────────────────────────────
# 应用版本只写在 AppScope/app.json5 的 versionName 里，这里在配置期读出来注入 C++，
# 供 User-Agent、Jellyfin 鉴权头的 Client 版本以及各模块自报版本使用。
# 起因：app.json5 已是 1.0.0，而 core/napi/player 与 User-Agent 还各自写着 0.1.0，
# 服务端仪表盘与 Sessions 里看到的应用版本互相矛盾。改版本只需改 app.json5 一处。
# 解析失败不致命：回退到下面的默认值（宿主单测不经 CMake，用 app_version.h 里的回退宏）。
# 回退值要跟着 app.json5 一起改，否则解析万一失败，各模块自报的版本会悄悄退回旧值。
set(JELLYFIN_APP_VERSION "1.1.0")
if(EXISTS "${NATIVEROOT}/app/AppScope/app.json5")
  file(READ "${NATIVEROOT}/app/AppScope/app.json5" JELLYFIN_APP_JSON5)
  string(REGEX MATCH "\"versionName\"[ \t]*:[ \t]*\"([^\"]+)\"" _APP_VERSION_MATCH "${JELLYFIN_APP_JSON5}")
  if(CMAKE_MATCH_1)
    set(JELLYFIN_APP_VERSION "${CMAKE_MATCH_1}")
  else()
    message(WARNING "未能从 AppScope/app.json5 解析 versionName，回退为 ${JELLYFIN_APP_VERSION}")
  endif()
endif()

target_compile_definitions(jellyfin_native PRIVATE
  MBEDTLS_CONFIG_FILE="jellyfin_mbedtls_config.h"
  JELLYFIN_APP_VERSION="${JELLYFIN_APP_VERSION}"
)

message(STATUS "应用版本：${JELLYFIN_APP_VERSION}（取自 AppScope/app.json5 的 versionName）")

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
#
# ⚠ ABI 打包事实（实测，2026-09-18）：`abiFilters` 只决定**hvigor 编哪些 ABI**，
# 不决定**打包哪些库**——`entry/libs/` 下的每个 <abi> 子目录都会被原样打进 HAP。
# 所以"只给真机的精简包"必须在打包前把 entry/libs/x86_64 移开，
# 单靠目标级 abiFilters 挡不住它（见 .github/workflows/release.yml 的 arm64 步骤）。
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
  # ── libdav1d（AV1 软解码器，libavcodec 的 DT_NEEDED 依赖）──────────────────
  # 为什么必须显式链接：libavcodec.so 的 DT_NEEDED 里有 `libdav1d.so.7`，
  # 运行期由动态链接器从 HAP 的 libs 目录解析；构建期把它一起链上，
  # 一是让链接器能校验这个依赖确实存在（缺库时立刻报错，而不是装到设备上才崩），
  # 二是保证 `entry/libs/<abi>/libdav1d.so` 被当作本模块的依赖一并打进 HAP。
  # 头文件用仓库内 third_party/dav1d/include（随仓库提交），
  # 交叉编译与部署见 scripts/build_dav1d_ohos.sh。
  if(EXISTS "${FFMPEG_LINK_DIR}/libdav1d.so")
    add_library(dav1d SHARED IMPORTED)
    set_target_properties(dav1d PROPERTIES
      IMPORTED_LOCATION "${FFMPEG_LINK_DIR}/libdav1d.so"
    )
    target_include_directories(jellyfin_native PRIVATE "${THIRD_PARTY_ROOT}/dav1d/include")
    target_link_libraries(jellyfin_native PUBLIC dav1d)
    message(STATUS "AV1 软解：已链接 libdav1d（${FFMPEG_LINK_DIR}）")
  else()
    message(WARNING "AV1 软解：未找到 ${FFMPEG_LINK_DIR}/libdav1d.so —— 本构建的 AV1 只能走"
                    "FFmpeg 自带 av1 解码器（无硬件加速时恒解不出帧）。"
                    "请运行 scripts/build_dav1d_ohos.sh ${OHOS_ARCH}")
  endif()
  message(STATUS "FFmpeg 软解码：已链接（${FFMPEG_LINK_DIR}，ABI=${OHOS_ARCH}）")
else()
  message(STATUS "FFmpeg 软解码：未找到 ABI=${OHOS_ARCH} 的预编译库，本次构建不启用"
                 "（可运行 scripts/build_ffmpeg_ohos.sh ${OHOS_ARCH}）")
endif()
