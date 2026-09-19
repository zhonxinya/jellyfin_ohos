/**
 * Host-side unit tests for RangeCache（feature/player 的 HTTP Range 分页缓存）。
 *
 * 为什么单独给它写测试：这套分页/缓存/seek 逻辑此前只被设备上的软解间接跑到，
 * 出错时表现为"解码失败"，很难定位。抽成不依赖 FFmpeg 的组件后可在主机上直接覆盖：
 * 分页边界、跨页读、回退 seek、EOF、服务器忽略 Range(200)、错误传播、请求区间是否正确。
 *
 * Build (from repo root):
 *   g++ -std=c++17 -I native/feature/player native/core/tests/test_range_cache.cpp \
 *       native/feature/player/range_cache.cpp native/feature/player/range_fetcher.cpp -o test_range_cache
 */

#include "range_cache.h"
#include "range_fetcher.h"

#include <chrono>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

int gFailures = 0;

void Expect(bool condition, const std::string &name, const std::string &detail = std::string())
{
    if (condition) {
        std::cout << "ok   " << name << "\n";
    } else {
        std::cerr << "FAIL " << name;
        if (!detail.empty()) {
            std::cerr << " -> " << detail;
        }
        std::cerr << "\n";
        ++gFailures;
    }
}

/** 造一段可预测内容：第 i 字节 = 'A' + (i % 26) */
std::string MakeContent(size_t size)
{
    std::string out(size, '\0');
    for (size_t i = 0; i < size; ++i) {
        out[i] = static_cast<char>('A' + (i % 26));
    }
    return out;
}

/**
 * 记录每次请求的假取流器；behavior 决定是否支持 Range。
 *
 * **必须线程安全**：`RangeCache::startPrefetch()` 会在后台线程里调用这个取流器，
 * 而测试主线程同时会读请求计数与请求区间。此前两处都没有同步 —— ASan 实测会在
 * `ranges.emplace_back()` 重新分配数组时被后台线程读到旧内存而报
 * `heap-use-after-free`（本机 5 次复现 2 次；CI 上表现为 `test_range_cache` 偶发
 * segfault / exit 139，与本改动无关的 PR 也会被它挡住）。因此计数与区间列表一律用
 * 互斥量保护，读取走访问器。
 */
struct FakeServer {
    std::string content;
    bool ignoreRange = false;      // true → 忽略 Range，总是返回整片（HTTP 200）
    bool failFromByte = false;     // true → 起点 > 0 的请求返回 500（模拟中途不可 Range）
    mutable std::mutex mtx;
    int requests = 0;
    std::vector<std::pair<int64_t, int64_t>> ranges;

    /** 请求次数（线程安全快照） */
    int RequestCount() const
    {
        std::lock_guard<std::mutex> lock(mtx);
        return requests;
    }

    /** 第 index 次请求的区间 [start, end]（线程安全快照） */
    std::pair<int64_t, int64_t> RangeAt(size_t index) const
    {
        std::lock_guard<std::mutex> lock(mtx);
        return index < ranges.size() ? ranges[index] : std::make_pair<int64_t, int64_t>(-1, -1);
    }

    jellyfin::player::RangeFetchFn Fetcher()
    {
        return [this](const std::string &, int64_t start, int64_t end) {
            jellyfin::player::RangeResponse resp;
            {
                std::lock_guard<std::mutex> lock(mtx);
                ++requests;
                ranges.emplace_back(start, end);
            }
            if (ignoreRange) {
                resp.status = 200;
                resp.body = content;
                return resp;
            }
            if (failFromByte && start > 0) {
                resp.status = 500;
                resp.error = "server error";
                return resp;
            }
            if (end < 0) {
                end = static_cast<int64_t>(content.size()) - 1;
            }
            if (start < 0 || start >= static_cast<int64_t>(content.size())) {
                resp.status = 416;
                return resp;
            }
            const int64_t last = std::min<int64_t>(end, static_cast<int64_t>(content.size()) - 1);
            resp.status = 206;
            resp.body = content.substr(static_cast<size_t>(start),
                                       static_cast<size_t>(last - start + 1));
            return resp;
        };
    }
};

/** 顺序读完整个流，返回读到的内容 */
std::string DrainAll(jellyfin::player::RangeCache &cache, std::string &error, int chunkRead = 64)
{
    std::string out;
    std::vector<uint8_t> buf(static_cast<size_t>(chunkRead));
    for (;;) {
        const int n = cache.read(buf.data(), chunkRead, error);
        if (n < 0) {
            return out;
        }
        if (n == 0) {
            return out;
        }
        out.append(reinterpret_cast<const char *>(buf.data()), static_cast<size_t>(n));
    }
}

void TestSequentialReadAcrossChunks()
{
    FakeServer server;
    server.content = MakeContent(1000);
    jellyfin::player::SetRangeFetcher(server.Fetcher());

    // chunk=256 → 1000 字节需要 4 个 Range 请求（256/256/256/232）
    jellyfin::player::RangeCache cache("https://example.test/media.mkv", 256);
    const int64_t size = cache.probe();
    // 服务器支持 Range 且首块正好是整块时，**无法**从响应推断总长度
    // （RangeResponse 不含响应头，拿不到 Content-Range）。契约：返回 -1 表示"长度未知但可顺序读"。
    Expect(size == -1, "probe 在 Range 服务器上返回 -1（长度未知，可顺序读到 EOF）",
           "size=" + std::to_string(size));

    std::string error;
    const std::string got = DrainAll(cache, error);
    Expect(got == server.content, "顺序读完整内容与源一致",
           "got=" + std::to_string(got.size()) + " want=" + std::to_string(server.content.size()));
    Expect(error.empty(), "顺序读无错误", error);
    Expect(cache.size() == 1000, "读到末尾后总长度被推断出来",
           "size=" + std::to_string(cache.size()));
    Expect(server.RequestCount() >= 4, "跨分片时发生多次 Range 请求",
           "requests=" + std::to_string(server.RequestCount()));
    Expect(server.RangeAt(0).first == 0 && server.RangeAt(0).second == 255,
           "首个 Range 请求区间为 0-255",
           std::to_string(server.RangeAt(0).first) + "-" + std::to_string(server.RangeAt(0).second));
    // 末尾之后的读取必须是 EOF 而不是错误（否则 libavformat 会收到 EIO）
    std::vector<uint8_t> buf(16);
    Expect(cache.read(buf.data(), 16, error) == 0, "读完后继续读返回 EOF(0) 而非错误");
    Expect(error.empty(), "末尾读取不产生错误信息", error);
}

void TestSeekBackwardsUsesCache()
{
    FakeServer server;
    server.content = MakeContent(1000);
    jellyfin::player::SetRangeFetcher(server.Fetcher());
    jellyfin::player::RangeCache cache("https://example.test/media.mkv", 512);
    cache.probe();
    const int requestsAfterProbe = server.RequestCount();

    std::string error;
    std::vector<uint8_t> buf(16);
    cache.seek(10);
    Expect(cache.read(buf.data(), 16, error) == 16, "seek 到 10 后可读 16 字节", error);
    Expect(std::string(reinterpret_cast<char *>(buf.data()), 16) == server.content.substr(10, 16),
           "seek 后读到正确位置的内容");

    // 回到已缓存区间内不应再发请求
    cache.seek(20);
    cache.read(buf.data(), 16, error);
    Expect(server.RequestCount() == requestsAfterProbe, "回退到已缓存区间不再发起请求",
           "requests=" + std::to_string(server.RequestCount()));

    // 跳到未缓存区间应触发新请求
    cache.seek(900);
    cache.read(buf.data(), 16, error);
    Expect(server.RequestCount() > requestsAfterProbe, "跳到未缓存区间触发新请求");
    Expect(std::string(reinterpret_cast<char *>(buf.data()), 16) == server.content.substr(900, 16),
           "跳转后内容正确");
}

void TestEofAndSeekClamp()
{
    FakeServer server;
    server.content = MakeContent(100);
    jellyfin::player::SetRangeFetcher(server.Fetcher());
    jellyfin::player::RangeCache cache("https://example.test/small.bin", 64);
    Expect(cache.probe() == -1, "小块文件在 Range 服务器上同样先返回 -1（长度未知）");
    Expect(cache.seek(-1) == -1, "负偏移 seek 被拒绝");

    std::string error;
    const std::string got = DrainAll(cache, error, 32);
    Expect(got == server.content, "小块文件也能顺序读完", "got=" + std::to_string(got.size()));
    Expect(error.empty(), "小块文件读到末尾无错误", error);
    Expect(cache.size() == 100, "小块文件长度在读到末尾后被推断出来",
           "size=" + std::to_string(cache.size()));

    // 长度已知后：越界 seek 被夹住，且读到末尾返回 EOF
    Expect(cache.seek(1000) == 100, "长度已知后越界 seek 被夹到文件长度");
    std::vector<uint8_t> buf(8);
    Expect(cache.read(buf.data(), 8, error) == 0, "定位到末尾后读返回 EOF(0)");
    Expect(error.empty(), "EOF 不作为错误上报", error);
}

void TestTailRange416TreatedAsEof()
{
    // 构造"长度未知 + 请求越过末尾"的场景：300 字节文件、chunk=128，
    // 首个分片正好是整块 → 长度未知；此时向远处请求会命中 416，必须当作 EOF 而非错误。
    FakeServer server;
    server.content = MakeContent(300);
    jellyfin::player::SetRangeFetcher(server.Fetcher());
    jellyfin::player::RangeCache cache("https://example.test/tiny.bin", 128);
    Expect(cache.probe() == -1, "首块为整块时长度未知（-1）");
    Expect(cache.seek(500) == 500, "长度未知时 seek 不夹取（返回原偏移）");

    std::string error;
    std::vector<uint8_t> buf(16);
    Expect(cache.read(buf.data(), 16, error) == 0, "越过末尾的 416 被当作 EOF(0)");
    Expect(error.empty(), "416 不产生错误信息", error);
}

void TestServerIgnoresRange()
{
    FakeServer server;
    server.content = MakeContent(300);
    server.ignoreRange = true;
    jellyfin::player::SetRangeFetcher(server.Fetcher());
    jellyfin::player::RangeCache cache("https://example.test/plain.bin", 128);
    const int64_t size = cache.probe();
    Expect(size == 300, "服务器忽略 Range(200) 时以 body 长度作为总长度",
           "size=" + std::to_string(size));

    std::string error;
    const std::string got = DrainAll(cache, error, 64);
    Expect(got == server.content, "忽略 Range 的服务器也能顺序读完整内容");
}

void TestMidStreamRangeFailurePropagates()
{
    FakeServer server;
    server.content = MakeContent(1000);
    server.failFromByte = true;  // 起点 > 0 的请求全部 500
    jellyfin::player::SetRangeFetcher(server.Fetcher());
    jellyfin::player::RangeCache cache("https://example.test/broken.mkv", 256);
    cache.probe();

    std::string error;
    std::vector<uint8_t> buf(256);
    // 第一块已由 probe 缓存，读完 256 字节后需要新请求 → 失败
    int total = 0;
    int n = 0;
    while (total < 300 && (n = cache.read(buf.data(), 256, error)) > 0) {
        total += n;
    }
    Expect(n < 0, "中途取流失败时 read 返回 -1");
    Expect(!error.empty(), "失败时给出可读错误信息", error);
}

void TestNoFetcherInjected()
{
    jellyfin::player::SetRangeFetcher(nullptr);
    jellyfin::player::RangeCache cache("https://example.test/x.mkv", 256);
    const int64_t size = cache.probe();
    Expect(size == 0, "未注入 RangeFetcher 时 probe 返回 0（不静默成功）");

    std::string error;
    std::vector<uint8_t> buf(16);
    Expect(cache.read(buf.data(), 16, error) == -1, "未注入取流器时 read 返回错误");
    Expect(error.find("RangeFetcher") != std::string::npos,
           "错误信息指明未注入 RangeFetcher", error);
}

} // namespace

/**
 * 后台预取：把数据填到读取位置之前，读取路径就不再碰网络。
 *
 * 这是本次修复的核心断言 —— 设备上软解逐帧读取时，未命中缓存会在调用线程
 * （UI 线程）上做同步 HTTP，一次往返就把主线程阻塞 6 秒以上，系统判 appfreeze。
 */
void TestPrefetchFillsAheadOfReader()
{
    FakeServer server;
    server.content = MakeContent(4096);
    jellyfin::player::SetRangeFetcher(server.Fetcher());

    jellyfin::player::RangeCache cache("https://example.test/media.mkv", 512);
    cache.probe();
    const int afterProbe = server.RequestCount();   // probe 已经取了第 0 块

    cache.startPrefetch(4);
    // 给预取线程一点时间跑起来（4 块 × 512B）
    for (int i = 0; i < 40 && server.RequestCount() < afterProbe + 4; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const int afterPrefetch = server.RequestCount();
    cache.stopPrefetch();

    Expect(afterPrefetch >= afterProbe + 3,
           "预取线程在读取之前就把后续分块取回",
           "probe 后请求数=" + std::to_string(afterProbe) +
               "，预取后=" + std::to_string(afterPrefetch));

    // 读取已在缓存里的范围**不应**再产生任何网络请求
    std::string error;
    std::vector<uint8_t> buf(64);
    for (int i = 0; i < 8; ++i) {
        cache.read(buf.data(), 64, error);
    }
    Expect(server.RequestCount() == afterPrefetch,
           "读取预取范围内的数据不产生新的取流请求（关键：网络不在读取路径上）",
           "读取后请求数=" + std::to_string(server.RequestCount()) +
               "，读取前=" + std::to_string(afterPrefetch));
}

/** 跨过预取窗口后再读：允许退化为同步取流，但内容仍须正确 */
void TestPrefetchBeyondWindowStillReads()
{
    FakeServer server;
    server.content = MakeContent(2048);
    jellyfin::player::SetRangeFetcher(server.Fetcher());

    jellyfin::player::RangeCache cache("https://example.test/media.mkv", 256);
    cache.probe();
    cache.startPrefetch(2);
    std::this_thread::sleep_for(std::chrono::milliseconds(30));

    std::string error;
    const std::string got = DrainAll(cache, error, 128);
    cache.stopPrefetch();

    Expect(got == server.content, "开启预取后仍能顺序读完整内容",
           "读到 " + std::to_string(got.size()) + " 字节");
    Expect(cache.prefetchRequests() > 0, "预取计数被记录（诊断用）",
           "prefetchRequests=" + std::to_string(cache.prefetchRequests()));
}

/** 停止预取是幂等的，且停止后不再发起请求（避免离开播放页后还在后台拉流） */
void TestStopPrefetchIsIdempotent()
{
    FakeServer server;
    server.content = MakeContent(8192);
    jellyfin::player::SetRangeFetcher(server.Fetcher());

    jellyfin::player::RangeCache cache("https://example.test/media.mkv", 512);
    cache.probe();
    cache.startPrefetch(8);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    cache.stopPrefetch();
    cache.stopPrefetch();   // 幂等
    const int atStop = server.RequestCount();
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    Expect(server.RequestCount() == atStop, "停止预取后不再发起取流请求",
           "停止后请求数=" + std::to_string(atStop) +
               "，等待后=" + std::to_string(server.RequestCount()));
}

/**
 * 回归：**缓存里塞满"远处的块"时，正在读的那一块不能被淘汰**。
 *
 * 设备实测的故障现场（HEVC 1080p，MP4 的 moov 在文件末尾）：
 *   ① 解复用器先跳到文件末尾读索引 → `pos_` 抬到 673MB 一带，缓存被远块填满；
 *   ② 回头顺序读开头时，缓存里没有任何"pos_ 之前的块" → 旧实现走 `chunks_.begin()`
 *      分支，而 begin() 恰好是**刚取回来的、正在读的第 0 块** → 立刻被淘汰；
 *   ③ 读不到 → 再取 → 再淘汰 …… 实测一次播放发出上千个 Range 请求、
 *      某次拉帧 20 秒不返回（上层看门狗判"软解卡死"）。
 * 这里用 1 字节/块的极小粒度复现同一结构：先把位置推到很远处的块上，再回到开头读。
 */
void TestEvictionNeverDropsTheChunkBeingRead()
{
    FakeServer server;
    server.content = MakeContent(256 * 1024);
    jellyfin::player::SetRangeFetcher(server.Fetcher());

    // chunk = 1024B；缓存上限 12 块（见 RangeCache::maxChunks_）
    jellyfin::player::RangeCache cache("https://example.test/media.mp4", 1024);
    cache.probe();                       // 取回第 0 块（模拟"读文件头"）
    const int afterProbe = server.RequestCount();

    // ① 模拟"跳到文件末尾读 moov"：在远离开头的位置散点读，把缓存塞满远块
    //    （散点是为了每块各自形成一个缓存分块，共 13 块 > 上限 12）
    std::string error;
    std::vector<uint8_t> buf(256);
    for (int i = 0; i < 13; ++i) {
        cache.seek(200 * 1024 + i * 2048);
        cache.read(buf.data(), static_cast<int>(buf.size()), error);
    }
    const int afterFarReads = server.RequestCount();

    // ② 回到开头连续读：这正是设备上"moov 在文件末尾的 MP4"的访问顺序
    cache.seek(0);
    bool contentOk = true;
    int reads = 0;
    for (int i = 0; i < 4; ++i) {
        const int n = cache.read(buf.data(), static_cast<int>(buf.size()), error);
        if (n != static_cast<int>(buf.size())) {
            contentOk = false;
            break;
        }
        ++reads;
        for (int k = 0; k < n; ++k) {
            const char want = static_cast<char>('A' + (((i * buf.size()) + static_cast<size_t>(k)) % 26));
            if (buf[static_cast<size_t>(k)] != want) {
                contentOk = false;
                break;
            }
        }
        if (!contentOk) {
            break;
        }
    }
    const int afterBackReads = server.RequestCount();
    cache.stopPrefetch();

    // 4 次 256B 读取全落在第 0 块内：只允许 1 次取流（旧实现会因为
    // "刚存的块立刻被淘汰"而每次读都重取，甚至一次都读不出来）
    Expect(contentOk,
           "从文件末尾回到开头读，内容仍然正确",
           "成功读取次数=" + std::to_string(reads));
    Expect(afterBackReads - afterFarReads <= 1,
           "回到开头读取不会反复重取同一块（淘汰策略不得丢掉正在读的块）",
           "远处读之后请求数=" + std::to_string(afterFarReads) +
               "，回到开头后=" + std::to_string(afterBackReads) +
               "（probe 后=" + std::to_string(afterProbe) + "）");
}

int main()
{
    std::cout << "== RangeCache 主机单测 ==\n";
    TestSequentialReadAcrossChunks();
    TestSeekBackwardsUsesCache();
    TestEofAndSeekClamp();
    TestTailRange416TreatedAsEof();
    TestServerIgnoresRange();
    TestMidStreamRangeFailurePropagates();
    TestNoFetcherInjected();
    TestPrefetchFillsAheadOfReader();
    TestPrefetchBeyondWindowStillReads();
    TestStopPrefetchIsIdempotent();
    TestEvictionNeverDropsTheChunkBeingRead();

    if (gFailures == 0) {
        std::cout << "All range cache tests passed\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed\n";
    return 1;
}
