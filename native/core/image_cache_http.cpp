#include "image_cache_http.h"

#include "http_client.h"
#include "image_cache.h"

#include <string>

namespace jellyfin {
namespace {

/**
 * 默认图片下载实现：core 的 `HttpClient`（自带 mbedTLS/https）。
 *
 * 凭据只走请求头（见 `image_url.cpp` 的安全约定）：URL 会进服务端访问日志。
 */
bool DownloadViaHttpClient(const std::string &url, const HttpHeaders &headers,
                           std::string &body, std::string &error)
{
    HttpClient http;
    // 图片可能是大图（4K 海报），给足读超时；连接超时沿用 HttpClient 默认值。
    http.setReadTimeoutSec(60);

    HttpHeaders requestHeaders = headers;
    if (requestHeaders.find("Accept") == requestHeaders.end()) {
        requestHeaders["Accept"] = "*/*";
    }

    const HttpResponse resp = http.get(url, requestHeaders);
    if (!resp.error.empty() || resp.status < 200 || resp.status >= 300 || resp.body.empty()) {
        error = resp.error.empty() ? ("HTTP " + std::to_string(resp.status)) : resp.error;
        return false;
    }
    body = resp.body;
    return true;
}

} // namespace

void InstallHttpImageDownloader()
{
    ImageCache::instance().setDownloader(DownloadViaHttpClient);
}

} // namespace jellyfin
