# Copyright (c) 2026 zhonxinya
# Jellyfin HMOS native shared library (NAPI)

cmake_minimum_required(VERSION 3.16.0)
project(jellyfin_native)

# cpp -> main -> src -> entry -> app -> native
set(NATIVEROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../..")

set(NAPI_ROOT "${NATIVEROOT}/napi")
set(CORE_ROOT "${NATIVEROOT}/core")
set(PLAYER_ROOT "${NATIVEROOT}/player")
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
)
