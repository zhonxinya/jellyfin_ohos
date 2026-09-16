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

} // namespace jellyfin

#endif /* JELLYFIN_CORE_URL_UTIL_H */
