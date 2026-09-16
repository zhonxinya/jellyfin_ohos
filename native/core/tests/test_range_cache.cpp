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

#include <cstdint>
#include <iostream>
#include <string>
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

/** 记录每次请求的假取流器；behavior 决定是否支持 Range */
struct FakeServer {
    std::string content;
    bool ignoreRange = false;      // true → 忽略 Range，总是返回整片（HTTP 200）
    bool failFromByte = false;     // true → 起点 > 0 的请求返回 500（模拟中途不可 Range）
    int requests = 0;
    std::vector<std::pair<int64_t, int64_t>> ranges;

    jellyfin::player::RangeFetchFn Fetcher()
    {
        return [this](const std::string &, int64_t start, int64_t end) {
            jellyfin::player::RangeResponse resp;
            ++requests;
            ranges.emplace_back(start, end);
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
    Expect(server.requests >= 4, "跨分片时发生多次 Range 请求",
           "requests=" + std::to_string(server.requests));
    Expect(server.ranges[0].first == 0 && server.ranges[0].second == 255,
           "首个 Range 请求区间为 0-255",
           std::to_string(server.ranges[0].first) + "-" + std::to_string(server.ranges[0].second));
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
    const int requestsAfterProbe = server.requests;

    std::string error;
    std::vector<uint8_t> buf(16);
    cache.seek(10);
    Expect(cache.read(buf.data(), 16, error) == 16, "seek 到 10 后可读 16 字节", error);
    Expect(std::string(reinterpret_cast<char *>(buf.data()), 16) == server.content.substr(10, 16),
           "seek 后读到正确位置的内容");

    // 回到已缓存区间内不应再发请求
    cache.seek(20);
    cache.read(buf.data(), 16, error);
    Expect(server.requests == requestsAfterProbe, "回退到已缓存区间不再发起请求",
           "requests=" + std::to_string(server.requests));

    // 跳到未缓存区间应触发新请求
    cache.seek(900);
    cache.read(buf.data(), 16, error);
    Expect(server.requests > requestsAfterProbe, "跳到未缓存区间触发新请求");
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

    if (gFailures == 0) {
        std::cout << "All range cache tests passed\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed\n";
    return 1;
}
