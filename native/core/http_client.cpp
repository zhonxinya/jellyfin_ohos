#include "http_client.h"

#include "http_response.h"
#include "http_tls.h"
#include "socket_util.h"
#include "url_util.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <sstream>
#include <string>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace jellyfin {
namespace {

struct ParsedUrl {
    std::string scheme;
    std::string host;
    int port = 80;
    std::string path; // includes query, starts with /
};

bool ParseHttpUrl(const std::string &url, ParsedUrl &out, std::string &error)
{
    out = ParsedUrl{};
    const auto schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos) {
        error = "Invalid URL: missing scheme";
        return false;
    }
    out.scheme = url.substr(0, schemeEnd);
    for (char &c : out.scheme) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    if (out.scheme == "https") {
        out.port = 443;
    } else if (out.scheme != "http") {
        error = "Unsupported URL scheme (only http:// and https:// are supported)";
        return false;
    }

    std::string rest = url.substr(schemeEnd + 3);
    if (rest.empty()) {
        error = "Invalid URL: empty host";
        return false;
    }

    std::string hostPort;
    const auto slash = rest.find('/');
    if (slash == std::string::npos) {
        hostPort = rest;
        out.path = "/";
    } else {
        hostPort = rest.substr(0, slash);
        out.path = rest.substr(slash);
        if (out.path.empty()) {
            out.path = "/";
        }
    }

    const auto colon = hostPort.rfind(':');
    // IPv6 in brackets not required for LAN MVP; treat last : as port if present.
    if (colon != std::string::npos && hostPort.find(']') == std::string::npos) {
        out.host = hostPort.substr(0, colon);
        try {
            out.port = std::stoi(hostPort.substr(colon + 1));
        } catch (...) {
            error = "Invalid URL port";
            return false;
        }
    } else {
        out.host = hostPort;
        out.port = (out.scheme == "https") ? 443 : 80;
    }

    if (out.host.empty()) {
        error = "Invalid URL: empty host";
        return false;
    }
    return true;
}

bool SetNonBlocking(int fd, bool enabled)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return false;
    }
    if (enabled) {
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
    }
    return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0;
}

bool DisableTcpKeepAlive(int fd)
{
    int off = 0;
    return setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &off, sizeof(off)) == 0;
}

bool IsHopByHopHeader(const std::string &name)
{
    std::string lower = name;
    for (char &c : lower) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return lower == "connection" || lower == "keep-alive" || lower == "proxy-connection";
}

int ConnectTcp(const std::string &host, int port, int timeoutSec, std::string &error)
{
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo *res = nullptr;
    const std::string portStr = std::to_string(port);
    int gai = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
    if (gai != 0) {
        error = std::string("DNS lookup failed: ") + gai_strerror(gai);
        return -1;
    }

    // Start non-blocking connects on every candidate address and race them, so a
    // broken IPv6 route cannot stall an IPv4 reverse-proxy address for a full
    // connect timeout.
    constexpr size_t kMaxPendingConnects = 6;
    std::vector<int> pending;
    int lastErrno = 0;
    int sock = -1;
    for (addrinfo *p = res; p != nullptr && sock < 0; p = p->ai_next) {
        const int fd = static_cast<int>(socket(p->ai_family, p->ai_socktype, p->ai_protocol));
        if (fd < 0) {
            lastErrno = errno;
            continue;
        }
        if (!SetNonBlocking(fd, true)) {
            lastErrno = errno;
            close(fd);
            continue;
        }
        if (connect(fd, p->ai_addr, static_cast<socklen_t>(p->ai_addrlen)) == 0) {
            sock = fd;
            break;
        }
        if (errno == EINPROGRESS && pending.size() < kMaxPendingConnects) {
            pending.push_back(fd);
            continue;
        }
        lastErrno = errno;
        close(fd);
    }
    freeaddrinfo(res);

    timespec deadline{};
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += timeoutSec;

    while (sock < 0 && !pending.empty()) {
        fd_set writeSet;
        FD_ZERO(&writeSet);
        int maxFd = -1;
        for (const int fd : pending) {
            FD_SET(fd, &writeSet);
            maxFd = std::max(maxFd, fd);
        }
        timespec now{};
        clock_gettime(CLOCK_MONOTONIC, &now);
        const long long remainingMs = (deadline.tv_sec - now.tv_sec) * 1000LL +
                                      (deadline.tv_nsec - now.tv_nsec) / 1000000LL;
        if (remainingMs <= 0) {
            lastErrno = ETIMEDOUT;
            break;
        }
        timeval tv{};
        tv.tv_sec = static_cast<long>(remainingMs / 1000);
        tv.tv_usec = static_cast<suseconds_t>((remainingMs % 1000) * 1000);
        const int rc = select(maxFd + 1, nullptr, &writeSet, nullptr, &tv);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            lastErrno = errno;
            break;
        }
        if (rc == 0) {
            lastErrno = ETIMEDOUT;
            break;
        }
        std::vector<int> next;
        for (const int fd : pending) {
            if (sock >= 0) {
                next.push_back(fd);
                continue;
            }
            if (!FD_ISSET(fd, &writeSet)) {
                next.push_back(fd);
                continue;
            }
            int soError = 0;
            socklen_t len = sizeof(soError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) < 0) {
                lastErrno = errno;
            } else if (soError == 0) {
                sock = fd;
                continue;
            } else {
                lastErrno = soError;
            }
            close(fd);
        }
        pending.swap(next);
    }
    for (const int fd : pending) {
        // 只关闭"未被选中的"候选 fd：
        // - 排除 sock：选中的 fd 是本次连接要用的，误关它会让后续 send/recv 作用在
        //   已关闭（甚至已被复用）的 fd 上；
        // - 排除负值：对无效 fd 调 close()/fcntl() 会被 musl FORTIFY 的 __fd_chk 直接 abort
        //   （设备实测：崩溃栈正是 HttpClient::get → request → ConnectTcp(__fd_chk)）。
        if (fd >= 0 && fd != sock) {
            close(fd);
        }
    }

    if (sock < 0) {
        if (lastErrno == ETIMEDOUT) {
            error = "TCP connect failed: timeout after " + std::to_string(timeoutSec) + "s";
        } else if (lastErrno != 0) {
            error = std::string("TCP connect failed: ") + std::strerror(lastErrno) +
                    " (errno=" + std::to_string(lastErrno) + ")";
        } else {
            error = "TCP connect failed";
        }
        return -1;
    }
    SetNonBlocking(sock, false);
    DisableTcpKeepAlive(sock);
    return sock;
}

bool SendAll(int sock, const std::string &data, int timeoutSec, std::string &error)
{
    size_t sent = 0;
    while (sent < data.size()) {
        if (WaitSocketReady(sock, true, timeoutSec) <= 0) {
            error = "Send timeout";
            return false;
        }
        ssize_t n = ::send(sock, data.data() + sent, data.size() - sent, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = std::string("Send failed: ") + std::strerror(errno);
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool RecvAll(int sock, std::string &out, int timeoutSec, std::string &error)
{
    out.clear();
    char buf[4096];
    while (true) {
        if (WaitSocketReady(sock, false, timeoutSec) <= 0) {
            // Treat timeout with partial data as end if we already have headers+body.
            if (!out.empty()) {
                break;
            }
            error = "Read timeout";
            return false;
        }
        ssize_t n = ::recv(sock, buf, sizeof(buf), 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = std::string("Recv failed: ") + std::strerror(errno);
            return false;
        }
        if (n == 0) {
            break;
        }
        out.append(buf, static_cast<size_t>(n));
        // Cap response size for safety (32 MiB).
        if (out.size() > 32u * 1024u * 1024u) {
            error = "Response too large";
            return false;
        }
    }
    return true;
}

} // namespace

HttpResponse HttpClient::get(const std::string &url, const HttpHeaders &headers) const
{
    return request("GET", url, {}, headers);
}

HttpResponse HttpClient::post(const std::string &url, const std::string &body,
                              const HttpHeaders &headers) const
{
    return request("POST", url, body, headers);
}

HttpResponse HttpClient::del(const std::string &url, const HttpHeaders &headers) const
{
    return request("DELETE", url, {}, headers);
}

HttpResponse HttpClient::request(const std::string &method, const std::string &url,
                                 const std::string &body, const HttpHeaders &headers) const
{
    HttpResponse resp;
    ParsedUrl parsed;
    if (!ParseHttpUrl(url, parsed, resp.error)) {
        return resp;
    }

    const bool useTls = parsed.scheme == "https";
    int sock = ConnectTcp(parsed.host, parsed.port, connectTimeoutSec_, resp.error);
    if (sock < 0) {
        return resp;
    }

    TlsSession tls;
    if (useTls) {
        tls.setTimeouts(connectTimeoutSec_, readTimeoutSec_);
        SetNonBlocking(sock, true);
        if (!tls.open(sock, parsed.host, resp.error)) {
            return resp;
        }
    }

    const int defaultPort = useTls ? 443 : 80;
    std::ostringstream req;
    req << method << " " << parsed.path << " HTTP/1.1\r\n";
    req << "Host: " << parsed.host;
    if (parsed.port != defaultPort) {
        req << ":" << parsed.port;
    }
    req << "\r\n";
    req << "User-Agent: JellyfinHarmonyOS/0.1.0\r\n";

    bool hasContentType = false;
    bool hasAccept = false;
    for (const auto &kv : headers) {
        if (IsHopByHopHeader(kv.first)) {
            continue;
        }
        std::string nameLower = kv.first;
        for (char &c : nameLower) {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        if (nameLower == "content-type") {
            hasContentType = true;
        }
        if (nameLower == "accept") {
            hasAccept = true;
        }
        req << kv.first << ": " << kv.second << "\r\n";
    }
    if (!hasAccept) {
        req << "Accept: application/json\r\n";
    }
    req << "Connection: close\r\n";
    if (!body.empty()) {
        if (!hasContentType) {
            req << "Content-Type: application/json\r\n";
        }
        req << "Content-Length: " << body.size() << "\r\n";
    } else if (method == "POST") {
        req << "Content-Length: 0\r\n";
    }
    req << "\r\n";
    if (!body.empty()) {
        req << body;
    }

    const std::string payload = req.str();
    if (useTls) {
        if (!tls.write(payload, resp.error)) {
            tls.close();
            return resp;
        }
    } else if (!SendAll(sock, payload, readTimeoutSec_, resp.error)) {
        close(sock);
        return resp;
    }

    std::string raw;
    if (useTls) {
        while (true) {
            const size_t before = raw.size();
            std::string readErr;
            if (!tls.readAppend(raw, readErr)) {
                if (!readErr.empty() && raw.empty()) {
                    resp.error = readErr;
                    tls.close();
                    return resp;
                }
                break;
            }
            if (raw.size() == before) {
                break;
            }
            if (raw.size() > 32u * 1024u * 1024u) {
                resp.error = "Response too large";
                tls.close();
                return resp;
            }
            if (IsHttpResponseComplete(raw)) {
                break;
            }
        }
        if (raw.empty()) {
            resp.error = "Empty HTTPS response";
            tls.close();
            return resp;
        }
        tls.close();
    } else if (!RecvAll(sock, raw, readTimeoutSec_, resp.error)) {
        close(sock);
        return resp;
    } else {
        close(sock);
    }

    std::string parseErr;
    if (!ParseHttpResponse(raw, resp, parseErr)) {
        resp.error = parseErr;
        resp.status = 0;
        resp.body.clear();
    }
    return resp;
}

} // namespace jellyfin
