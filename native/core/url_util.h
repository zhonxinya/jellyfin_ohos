#ifndef JELLYFIN_CORE_URL_UTIL_H
#define JELLYFIN_CORE_URL_UTIL_H

#include <string>

namespace jellyfin {

/**
 * Normalize a Jellyfin base URL:
 * - trim leading/trailing whitespace
 * - require http:// or https:// scheme (lowercase scheme)
 * - remove a single trailing slash unless the path is exactly "/"
 * - preserve reverse-proxy path segments (e.g. http://host/jellyfin)
 */
std::string NormalizeBaseUrl(const std::string &input);

/** True when the URL uses https://. */
bool IsHttpsUrl(const std::string &url);

/** Join baseUrl (already normalized, no trailing slash) with a relative path starting with /. */
std::string JoinUrl(const std::string &baseUrl, const std::string &path);

/**
 * Percent-encode a query-string value（RFC 3986 的 unreserved 字符原样保留）。
 *
 * - 空格编码为 `+`：Jellyfin 服务端（ASP.NET）在 query string 里把 `+` 解析为空格，
 *   设备实测 `SearchTerm=铁达尼+号` 与 `%20` 返回结果一致；
 * - 非 ASCII（中文）按 UTF-8 逐字节编码 —— 实测服务端能正确解出中文搜索词。
 */
std::string EncodeQueryComponent(const std::string &value);

} // namespace jellyfin

#endif /* JELLYFIN_CORE_URL_UTIL_H */
