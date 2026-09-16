#ifndef JELLYFIN_CORE_HTTP_TLS_H
#define JELLYFIN_CORE_HTTP_TLS_H

#include <string>

namespace jellyfin {

/**
 * Wraps a connected TCP socket with TLS (mbedTLS) for HTTPS.
 *
 * 证书校验：默认**要求**校验（MBEDTLS_SSL_VERIFY_REQUIRED）并同时校验主机名。
 * CA 根证书由宿主（ArkTS）在启动时通过 `SetCaBundlePath()` 指定一个 PEM 文件路径
 * （应用内自带 Mozilla CA bundle，脱机可用）；未配置或加载失败时 https 连接会**失败并报错**，
 * 而不是静默跳过校验（旧实现用 VERIFY_OPTIONAL + 空 CA 链，等于不校验，可被中间人攻击）。
 */
class TlsSession {
public:
    TlsSession() = default;
    ~TlsSession();

    TlsSession(const TlsSession &) = delete;
    TlsSession &operator=(const TlsSession &) = delete;

    /**
     * 设置 CA 根证书 PEM 文件路径（进程级，一次即可）。
     * @return 是否成功解析出至少一张证书
     */
    static bool SetCaBundlePath(const std::string &pemPath);

    /** 当前是否已加载 CA 根证书（供状态查询/诊断） */
    static bool HasCaBundle();

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
