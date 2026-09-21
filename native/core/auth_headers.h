#ifndef JELLYFIN_CORE_AUTH_HEADERS_H
#define JELLYFIN_CORE_AUTH_HEADERS_H

#include "http_client.h"

#include <string>

namespace jellyfin {

/**
 * 构造 Jellyfin 鉴权请求头。
 *
 * ## 为什么必须用请求头而不是 `?api_key=<token>`
 *
 * Jellyfin 把每个请求的 URL 写进服务端访问日志（`Jellyfin.log`）。
 * 旧实现把访问令牌拼进图片/字幕 URL 的 query，设备实测在服务端日志里留下了
 * **147 处** `api_key=<token>` —— 令牌等于被明文落盘到服务器上，
 * 任何能读日志的人（运维、备份、日志采集）都能直接拿到用户凭据。
 * URL 还会经 Referer、代理访问日志、崩溃上报等渠道继续扩散。
 *
 * 因此约定：**凭据一律走 `X-Emby-Authorization` 请求头，禁止进入 URL。**
 * 注意唯一例外是播放地址（`feature/player` 的 `RangeFetchFn` 只接受 URL，
 * 见 `native/feature/player/range_fetcher.h` 的接口注释）；要消除那一处
 * 需要先改播放模块的接口设计，不在本约定覆盖范围内。
 *
 * 头内容与服务端 `api_client.cpp` 保持一致，避免两套鉴权表达。
 *
 * @param token 访问令牌；为空时返回不带头部的空表（调用方应视为未鉴权）
 */
inline HttpHeaders BuildAuthHeaders(const std::string &token)
{
    HttpHeaders headers;
    if (token.empty()) {
        return headers;
    }
    // Jellyfin/Emby 同时接受 X-Emby-Token 与 Authorization 两种表达；
    // 这里用最直接的 Token 形式，语义清晰且不需要拼接客户端信息。
    headers["X-Emby-Token"] = token;
    headers["Authorization"] = "MediaBrowser Token=\"" + token + "\"";
    return headers;
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_AUTH_HEADERS_H */
