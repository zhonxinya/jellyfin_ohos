#ifndef JELLYFIN_CORE_HTTP_CLIENT_H
#define JELLYFIN_CORE_HTTP_CLIENT_H

#include <map>
#include <string>

namespace jellyfin {

struct HttpResponse {
    int status = 0;
    std::string body;
    std::string error; // non-empty on transport / unsupported-scheme failure
};

using HttpHeaders = std::map<std::string, std::string>;

/**
 * HTTP/1.1 client: plain http:// over POSIX sockets, https:// via mbedTLS.
 * Each request opens a fresh TCP (+ TLS) connection; keep-alive is never used.
 */
class HttpClient {
public:
    HttpResponse get(const std::string &url, const HttpHeaders &headers = {}) const;
    HttpResponse post(const std::string &url, const std::string &body,
                      const HttpHeaders &headers = {}) const;
    HttpResponse del(const std::string &url, const HttpHeaders &headers = {}) const;

    void setConnectTimeoutSec(int seconds) { connectTimeoutSec_ = seconds; }
    void setReadTimeoutSec(int seconds) { readTimeoutSec_ = seconds; }

private:
    HttpResponse request(const std::string &method, const std::string &url,
                         const std::string &body, const HttpHeaders &headers) const;

    int connectTimeoutSec_ = 10;
    int readTimeoutSec_ = 30;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_HTTP_CLIENT_H */
