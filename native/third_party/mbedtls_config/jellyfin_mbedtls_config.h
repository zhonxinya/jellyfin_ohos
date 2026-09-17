#ifndef JELLYFIN_MBEDTLS_CONFIG_H
#define JELLYFIN_MBEDTLS_CONFIG_H

/* Full upstream config; build_info.h applies dependency adjustments and check_config. */
#include "mbedtls/mbedtls_config.h"

/*
 * 项目裁剪：**关闭 TLS 1.3**，仅使用 TLS 1.2。
 *
 * 原因（设备实测崩溃，faultlog 实证）：开启 TLS 1.3 时握手路径
 *   mbedtls_ssl_tls13_compute_handshake_transform()
 * 在本工程构建下触发 `Signal: SIGFPE (FPE_INTDIV)`（整数除零）并**打挂整个应用**，
 * 表现为"打开应用/进入播放页后莫名退回桌面"，且间歇出现（只有部分握手走到该分支）：
 *   #00 ld-musl-x86_64.so.1(calloc+47)
 *   #01 libjellyfin_native.so
 *   #02 libjellyfin_native.so(mbedtls_ssl_tls13_compute_handshake_transform+72)
 *
 * 取舍：Jellyfin 服务端普遍支持 TLS 1.2（本工程测试服务器亦支持），
 * "应用不崩"优先级远高于"用上 TLS 1.3"。待确认 mbedTLS 该缺陷修复后可移除本裁剪并回归验证。
 */
#undef MBEDTLS_SSL_PROTO_TLS1_3
#undef MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_ALL_ENABLED
#undef MBEDTLS_SSL_EARLY_DATA

#endif /* JELLYFIN_MBEDTLS_CONFIG_H */
