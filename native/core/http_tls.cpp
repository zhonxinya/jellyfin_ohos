#include "http_tls.h"

#include "socket_util.h"

#include <cerrno>
#include <cstring>
#include <mutex>
#include <vector>

#include <sys/socket.h>
#include <unistd.h>

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

namespace jellyfin {
namespace {

/** 进程级 CA 根证书（由宿主通过 SetCaBundlePath 加载一次，多连接复用） */
mbedtls_x509_crt g_caBundle;
std::mutex g_caMutex;
bool g_caInited = false;
bool g_caLoaded = false;

} // namespace

bool TlsSession::SetCaBundlePath(const std::string &pemPath)
{
    std::lock_guard<std::mutex> lock(g_caMutex);
    if (!g_caInited) {
        mbedtls_x509_crt_init(&g_caBundle);
        g_caInited = true;
    }
    g_caLoaded = false;
    if (pemPath.empty()) {
        return false;
    }
    const int rc = mbedtls_x509_crt_parse_file(&g_caBundle, pemPath.c_str());
    if (rc < 0) {
        return false;
    }
    g_caLoaded = g_caBundle.next != nullptr;
    return g_caLoaded;
}

bool TlsSession::HasCaBundle()
{
    std::lock_guard<std::mutex> lock(g_caMutex);
    return g_caLoaded;
}

namespace {

int BioSend(void *ctx, const unsigned char *buf, size_t len)
{
    const int fd = *static_cast<int *>(ctx);
    // Single send call: mbedtls requires the exact sent-byte count (or WANT_WRITE
    // only when nothing was sent) to keep the TLS stream consistent.
    const ssize_t n = ::send(fd, buf, len, 0);
    if (n < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            return MBEDTLS_ERR_SSL_WANT_WRITE;
        }
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return static_cast<int>(n);
}

int BioRecv(void *ctx, unsigned char *buf, size_t len)
{
    const int fd = *static_cast<int *>(ctx);
    const ssize_t n = ::recv(fd, buf, len, 0);
    if (n < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            return MBEDTLS_ERR_SSL_WANT_READ;
        }
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    return static_cast<int>(n);
}

std::string MbedtlsError(int code)
{
    char buf[256];
    mbedtls_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}

} // namespace

struct TlsSession::Impl {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctrDrbg;
    mbedtls_x509_crt caChain;
    bool inited = false;

    Impl()
    {
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&ctrDrbg);
        mbedtls_x509_crt_init(&caChain);
        inited = true;
    }

    ~Impl()
    {
        if (!inited) {
            return;
        }
        mbedtls_x509_crt_free(&caChain);
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_ctr_drbg_free(&ctrDrbg);
        mbedtls_entropy_free(&entropy);
    }
};

TlsSession::~TlsSession()
{
    close();
    delete impl_;
    impl_ = nullptr;
}

bool TlsSession::open(int socketFd, const std::string &host, std::string &error)
{
    close();
    socketFd_ = socketFd;
    impl_ = new Impl();

    const char *pers = "jellyfin_hmos_tls";
    int rc = mbedtls_ctr_drbg_seed(&impl_->ctrDrbg, mbedtls_entropy_func, &impl_->entropy,
                                   reinterpret_cast<const unsigned char *>(pers), std::strlen(pers));
    if (rc != 0) {
        error = "TLS RNG init failed: " + MbedtlsError(rc);
        close();
        return false;
    }

    rc = mbedtls_ssl_config_defaults(&impl_->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                     MBEDTLS_SSL_PRESET_DEFAULT);
    if (rc != 0) {
        error = "TLS config failed: " + MbedtlsError(rc);
        close();
        return false;
    }

    // 证书校验：要求校验（含主机名）。CA 根证书来自宿主在启动时加载的 Mozilla bundle；
    // 未加载则明确失败——绝不静默跳过校验。
    {
        std::lock_guard<std::mutex> lock(g_caMutex);
        if (!g_caLoaded) {
            error = "HTTPS 不可用：未加载 CA 根证书（请确认应用启动时已配置 cacert.pem）";
            close();
            return false;
        }
        mbedtls_ssl_conf_authmode(&impl_->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&impl_->conf, &g_caBundle, nullptr);
    }
    mbedtls_ssl_conf_rng(&impl_->conf, mbedtls_ctr_drbg_random, &impl_->ctrDrbg);
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
    mbedtls_ssl_conf_session_tickets(&impl_->conf, MBEDTLS_SSL_SESSION_TICKETS_DISABLED);
#endif

    rc = mbedtls_ssl_setup(&impl_->ssl, &impl_->conf);
    if (rc != 0) {
        error = "TLS setup failed: " + MbedtlsError(rc);
        close();
        return false;
    }

    rc = mbedtls_ssl_set_hostname(&impl_->ssl, host.c_str());
    if (rc != 0) {
        error = "TLS SNI failed: " + MbedtlsError(rc);
        close();
        return false;
    }

    mbedtls_ssl_set_bio(&impl_->ssl, &socketFd_, BioSend, BioRecv, nullptr);

    while ((rc = mbedtls_ssl_handshake(&impl_->ssl)) != 0) {
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            const int wait = WaitSocketReady(socketFd_, rc == MBEDTLS_ERR_SSL_WANT_WRITE, connectTimeoutSec_);
            if (wait <= 0) {
                error = wait == 0 ? std::string("TLS handshake timeout")
                                  : std::string("TLS handshake failed: ") + std::strerror(errno);
                close();
                return false;
            }
            continue;
        }
        error = "TLS handshake failed: " + MbedtlsError(rc);
        close();
        return false;
    }

    open_ = true;
    return true;
}

bool TlsSession::write(const std::string &data, std::string &error)
{
    if (!open_ || impl_ == nullptr) {
        error = "TLS session not open";
        return false;
    }
    size_t offset = 0;
    while (offset < data.size()) {
        const int rc = mbedtls_ssl_write(&impl_->ssl, reinterpret_cast<const unsigned char *>(data.data() + offset),
                                         data.size() - offset);
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            const int wait = WaitSocketReady(socketFd_, rc == MBEDTLS_ERR_SSL_WANT_WRITE, readTimeoutSec_);
            if (wait <= 0) {
                error = wait == 0 ? std::string("TLS write timeout")
                                  : std::string("TLS write failed: ") + std::strerror(errno);
                return false;
            }
            continue;
        }
        if (rc <= 0) {
            error = "TLS write failed: " + MbedtlsError(rc);
            return false;
        }
        offset += static_cast<size_t>(rc);
    }
    return true;
}

bool TlsSession::readAppend(std::string &buffer, std::string &error)
{
    if (!open_ || impl_ == nullptr) {
        error = "TLS session not open";
        return false;
    }
    unsigned char buf[4096];
    while (true) {
        const int rc = mbedtls_ssl_read(&impl_->ssl, buf, sizeof(buf));
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
            const int wait = WaitSocketReady(socketFd_, rc == MBEDTLS_ERR_SSL_WANT_WRITE, readTimeoutSec_);
            if (wait <= 0) {
                error = wait == 0 ? std::string("TLS read timeout")
                                  : std::string("TLS read failed: ") + std::strerror(errno);
                return false;
            }
            continue;
        }
        if (rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || rc == 0) {
            break;
        }
        if (rc < 0) {
            error = "TLS read failed: " + MbedtlsError(rc);
            return false;
        }
        buffer.append(reinterpret_cast<char *>(buf), static_cast<size_t>(rc));
        if (buffer.size() > 32u * 1024u * 1024u) {
            error = "Response too large";
            return false;
        }
        // One read burst per call; caller loops like RecvAll until close.
        break;
    }
    return true;
}

void TlsSession::close()
{
    if (impl_ != nullptr && open_) {
        mbedtls_ssl_close_notify(&impl_->ssl);
    }
    open_ = false;
    if (socketFd_ >= 0) {
        ::close(socketFd_);
        socketFd_ = -1;
    }
    delete impl_;
    impl_ = nullptr;
}

} // namespace jellyfin
