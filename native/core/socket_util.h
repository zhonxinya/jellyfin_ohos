#ifndef JELLYFIN_CORE_SOCKET_UTIL_H
#define JELLYFIN_CORE_SOCKET_UTIL_H

#include <cerrno>
#include <sys/select.h>
#include <sys/time.h>

namespace jellyfin {

/**
 * Wait until fd becomes readable (forWrite == false) or writable (forWrite == true).
 * Returns 1 when ready, 0 on timeout, -1 on select error. EINTR is retried.
 */
inline int WaitSocketReady(int fd, bool forWrite, int timeoutSec)
{
    for (int retry = 0; retry < 16; ++retry) {
        fd_set set;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        timeval tv{};
        tv.tv_sec = timeoutSec;
        tv.tv_usec = 0;
        const int rc = select(fd + 1, forWrite ? nullptr : &set, forWrite ? &set : nullptr, nullptr, &tv);
        if (rc >= 0) {
            return rc > 0 ? 1 : 0;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
    return -1;
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_SOCKET_UTIL_H */
