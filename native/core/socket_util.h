#ifndef JELLYFIN_CORE_SOCKET_UTIL_H
#define JELLYFIN_CORE_SOCKET_UTIL_H

#include <cerrno>
#include <poll.h>

namespace jellyfin {

/**
 * Wait until fd becomes readable (forWrite == false) or writable (forWrite == true).
 * Returns 1 when ready, 0 on timeout, -1 on error. EINTR is retried.
 *
 * **为什么用 `poll()` 而不是 `select()`**（这是一个真机崩溃的修复）：
 * OpenHarmony 的 `<sys/select.h>` 把 `FD_SET` 定义成
 *
 *     void __fd_chk(int fd);   // "check fd(0 <= fd < 1024) is valid for select,
 *                              //  abort if not"
 *     #define FD_SET(d, s) do { __fd_chk(d); ... } while(0)
 *
 * 也就是**传入 fd ≥ 1024 会直接 abort 进程**。而本应用在设备上的 fd 上限是 32768
 * （`/proc/<pid>/limits` 实测 `Max open files 32768`），`select()` 的 1024 位
 * `fd_set` 只是它的 1/32 —— 只要进程瞬时持有 1024 个以上 fd，任何一次
 * `FD_SET` 都会把应用打死。
 *
 * 触发场景（设备实测崩溃栈 `__fd_chk → ConnectTcp → HttpClient::get →
 * ImageCache::getOrDownload → LoadImage`）：**详情页**会并发发起大量图片请求
 * （每张图一个 `RunAsync` 工作线程、各自一条 TCP 连接），fd 数量随图片数快速上升，
 * 于是"打开详情页约 20 秒后必崩"。`poll()` 没有 fd 宽度限制，天然规避这个问题。
 *
 * 顺带说明：`FD_ISSET` **不**受此限制（它自己带 `fd >= 0 && fd < FD_SETSIZE` 判断，
 * 越界只是返回 false），所以旧代码里"只有 FD_SET 会崩"这点也很反直觉 ——
 * 这也是同类问题容易被漏掉的原因。
 */
inline int WaitSocketReady(int fd, bool forWrite, int timeoutSec)
{
    if (fd < 0) {
        return -1;
    }
    // poll 的超时单位是毫秒；调用方给的是秒。
    const int timeoutMs = timeoutSec > 0 ? timeoutSec * 1000 : -1;
    for (int retry = 0; retry < 16; ++retry) {
        struct pollfd pfd {};
        pfd.fd = fd;
        pfd.events = forWrite ? POLLOUT : POLLIN;
        const int rc = poll(&pfd, 1, timeoutMs);
        if (rc >= 0) {
            if (rc == 0) {
                return 0;   // 超时
            }
            // `POLLNVAL` = 这个 fd 根本无效（已关闭 / 从未打开）。必须报错，
            // **不能**当成"就绪" —— 否则调用方会拿着一个坏 fd 去 read/write，
            // 把"参数错误"伪装成"连接有问题"，排查时会指向完全错误的方向。
            if ((pfd.revents & POLLNVAL) != 0) {
                return -1;
            }
            // 对端关闭（POLLHUP/POLLERR）也算"就绪"：交给后续 read/write 去拿到
            // 真实的错误码（0 字节读 / EPIPE），不在这里假装成功。
            return 1;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
    return -1;
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_SOCKET_UTIL_H */
