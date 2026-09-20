/**
 * `socket_util.h` 的 `WaitSocketReady()` 单测。
 *
 * 为什么值得单测：这个函数曾经用 `select()`，而 OpenHarmony 的 `<sys/select.h>`
 * 把 `FD_SET` 定义成"fd 必须在 [0,1024) 内，否则 `__fd_chk` **直接 abort**"：
 *
 *     void __fd_chk(int fd);   // "abort if not (0 <= fd < 1024)"
 *     #define FD_SET(d, s) do { __fd_chk(d); ... } while(0)
 *
 * 而本应用在设备上的 fd 上限是 32768。详情页并发加载图片时 fd 数越过 1024，
 * 于是一次 `FD_SET` 就把应用打死（设备实测崩溃栈
 * `__fd_chk → ConnectTcp → HttpClient::get → ImageCache::getOrDownload → LoadImage`，
 * 表现是"打开详情页约 20 秒后必崩"）。
 *
 * 主机侧没法复现"fd ≥ 1024"（要先把 1024 个 fd 都占上），但可以断言**契约**：
 * - 非法 fd（负数）必须返回 -1 而不是崩；
 * - 正常可读/可写 fd 必须正确就绪；
 * - 超时必须返回 0；
 * - 对端关闭必须算"就绪"（交给后续 read/write 拿真实错误码）。
 * 只要实现走的是 `poll()` 这条路，就不存在 fd 宽度上限 —— 这正是本测试守住的点。
 */
#include "socket_util.h"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <string>

#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

int g_failures = 0;

void ExpectTrue(bool cond, const std::string &what)
{
    if (!cond) {
        std::printf("  [FAIL] %s\n", what.c_str());
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

void ExpectEq(int got, int want, const std::string &what)
{
    if (got != want) {
        std::printf("  [FAIL] %s\n        实际=%d 期望=%d\n", what.c_str(), got, want);
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

/** 负 fd 必须被挡在函数入口，不能进到 FD_SET/select 里去 abort */
void TestInvalidFd()
{
    std::printf("非法 fd 不崩、返回 -1\n");
    ExpectEq(jellyfin::WaitSocketReady(-1, false, 1), -1, "fd=-1（读）返回 -1");
    ExpectEq(jellyfin::WaitSocketReady(-1, true, 1), -1, "fd=-1（写）返回 -1");
    ExpectEq(jellyfin::WaitSocketReady(-12345, false, 1), -1, "fd 为大负数也返回 -1");
}

/** 可写：刚建好的 socket 通常立刻可写 */
void TestWritableReady()
{
    std::printf("可写 fd 就绪\n");
    const int fds[2] = {-1, -1};
    int pair[2] = {-1, -1};
    (void)fds;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        std::printf("  [skip] socketpair 不可用\n");
        return;
    }
    ExpectEq(jellyfin::WaitSocketReady(pair[0], true, 2), 1, "socketpair 可写 → 1");
    // 可读侧此时没有数据：必须超时返回 0，不能误报就绪
    ExpectEq(jellyfin::WaitSocketReady(pair[1], false, 1), 0, "无数据可读 → 超时 0");
    close(pair[0]);
    close(pair[1]);
}

/** 有数据可读时必须就绪 */
void TestReadableReady()
{
    std::printf("有数据可读 → 就绪\n");
    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        std::printf("  [skip] socketpair 不可用\n");
        return;
    }
    const char payload = 'x';
    ssize_t written = ::write(pair[1], &payload, 1);
    ExpectTrue(written == 1, "写入 1 字节成功");
    ExpectEq(jellyfin::WaitSocketReady(pair[0], false, 2), 1, "有数据可读 → 1");
    close(pair[0]);
    close(pair[1]);
}

/**
 * 对端关闭必须算"就绪"。
 *
 * 语义要与旧的 `select()` 行为一致：对端关闭时 select 会把 fd 标为可读，
 * 后续 `recv` 返回 0 才代表连接结束。这里若误判为"未就绪"，接收循环会一直等到超时。
 */
void TestPeerClosedIsReady()
{
    std::printf("对端关闭 → 就绪（交给 recv 拿 0）\n");
    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        std::printf("  [skip] socketpair 不可用\n");
        return;
    }
    close(pair[1]);
    ExpectEq(jellyfin::WaitSocketReady(pair[0], false, 2), 1, "对端已关闭 → 1");
    char buf = 0;
    ExpectTrue(::read(pair[0], &buf, 1) == 0, "随后 recv/read 返回 0（连接结束）");
    close(pair[0]);
}

/** 必须真的等待超时，而不是立刻返回 */
void TestTimeoutWaits()
{
    std::printf("超时行为\n");
    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        std::printf("  [skip] socketpair 不可用\n");
        return;
    }
    const auto start = std::chrono::steady_clock::now();
    const int rc = jellyfin::WaitSocketReady(pair[0], false, 1);
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                               std::chrono::steady_clock::now() - start)
                               .count();
    ExpectEq(rc, 0, "无数据 → 0");
    ExpectTrue(elapsedMs >= 900, "确实等满了 ~1s（未提前返回）");
    close(pair[0]);
    close(pair[1]);
}

/**
 * 大 fd 不会崩。
 *
 * 这是本文件存在的**核心理由**：`select()` 版实现里，fd ≥ 1024 会让 `FD_SET`
 * 触发 `__fd_chk` → abort。用 `poll()` 后没有这个宽度上限，所以我们要能对
 * "一个大 fd 值"安全地返回（就绪或超时都行，**只要不崩**）。
 *
 * 主机上拿不到 1024 以上的真实 fd（需要先占满 1024 个），因此这里退一步：
 * 连开若干 socket 直到拿到 >= 1024 的 fd；拿不到就用高编号的**已关闭** fd 验证
 * "不崩、只是返回错误"。两种情形都只断言"没有异常终止"。
 */
void TestLargeFdDoesNotAbort()
{
    std::printf("大 fd 值不触发 abort\n");
    // 情形 A：直接把一个很大的 fd 号喂进去（模拟"fd 超过 select 的 1024 位"）。
    // 这个 fd 并不存在，所以只要求"安全返回 -1 或 0"，绝不能 abort。
    const int hugeFd = 5000;
    const int rc = jellyfin::WaitSocketReady(hugeFd, false, 0 /* 立刻超时，不阻塞 */);
    ExpectTrue(rc == -1 || rc == 0, "fd=5000（不存在）安全返回，不 abort");

    // 情形 B：占用一批 fd 直到越过 1024，然后验证这些"真实的大 fd"能用。
    // 上限 1100 —— 万一容器 fd 上限较小，拿不到就跳过（不把环境限制当失败）。
    constexpr int kTargetFd = 1050;
    int held[1200];
    int heldCount = 0;
    int bigFd = -1;
    for (int i = 0; i < 1200 && heldCount < 1200; ++i) {
        const int fd = ::dup(0);
        if (fd < 0) {
            break;
        }
        held[heldCount++] = fd;
        if (fd >= kTargetFd) {
            bigFd = fd;
            break;
        }
    }
    if (bigFd >= 0) {
        // 大 fd 上做一次"可写"等待。dup(0) 得到的 fd 是否可写取决于 stdin，
        // 所以不断言具体返回值，只断言**不崩**、返回值在合法集合内。
        const int rc2 = jellyfin::WaitSocketReady(bigFd, true, 0);
        ExpectTrue(rc2 == 1 || rc2 == 0 || rc2 == -1,
                   "真实 fd >= 1050 安全返回（poll 无 1024 宽度限制）");
        std::printf("        （实测拿到 fd=%d）\n", bigFd);
    } else {
        std::printf("  [skip] 本机未能把 fd 提到 %d（进程 fd 上限较小）\n", kTargetFd);
    }
    for (int i = 0; i < heldCount; ++i) {
        close(held[i]);
    }
}

} // namespace

int main()
{
    std::printf("== WaitSocketReady 单测 ==\n");
    TestInvalidFd();
    TestWritableReady();
    TestReadableReady();
    TestPeerClosedIsReady();
    TestTimeoutWaits();
    TestLargeFdDoesNotAbort();
    if (g_failures != 0) {
        std::printf("== 失败 %d 项 ==\n", g_failures);
        return 1;
    }
    std::printf("== 全部通过 ==\n");
    return 0;
}
