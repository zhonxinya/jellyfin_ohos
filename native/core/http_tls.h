#ifndef JELLYFIN_CORE_HTTP_TLS_H
#define JELLYFIN_CORE_HTTP_TLS_H

#include <string>

namespace jellyfin {

/**
 * Wraps a connected TCP socket with TLS (mbedTLS) for HTTPS.
 * Peer verification is enabled with system/default CA bundle when available;
 * self-signed Jellyfin certs may require user to use http:// on LAN.
 */
class TlsSession {
public:
    TlsSession() = default;
    ~TlsSession();

    TlsSession(const TlsSession &) = delete;
    TlsSession &operator=(const TlsSession &) = delete;

    /** Perform TLS handshake over an already-connected TCP socket fd. */
    bool open(int socketFd, const std::string &host, std::string &error);

    /** Timeouts (seconds) used while waiting for TLS socket readiness. */
    void setTimeouts(int connectTimeoutSec, int readTimeoutSec)
    {
        connectTimeoutSec_ = connectTimeoutSec;
        readTimeoutSec_ = readTimeoutSec;
    }

    bool write(const std::string &data, std::string &error);
    bool readAppend(std::string &buffer, std::string &error);

    void close();

    bool isOpen() const { return open_; }

private:
    struct Impl;
    Impl *impl_ = nullptr;
    int socketFd_ = -1;
    bool open_ = false;
    int connectTimeoutSec_ = 10;
    int readTimeoutSec_ = 30;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_HTTP_TLS_H */
