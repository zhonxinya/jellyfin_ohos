/**
 * Host-side unit tests for ImageCache（core 的磁盘图片缓存）。
 *
 * 为什么能脱离网络单测：`ImageCache` 只依赖**注入的**下载函数（`ImageDownloadFn`），
 * 不直接依赖 `HttpClient`/mbedTLS —— 本测试只需一个假下载器 + 一个临时目录，
 * 不必把网络栈拖进单测编译（与 player 的 `SetRangeFetcher` 同一模式）。
 *
 * 守住的回归点（都对应设备上实测过或读代码发现的问题）：
 *  1. **淘汰的触发频率**：旧实现在 `finishDownload()` 里每下载完一张图就扫一次缓存目录，
 *     而淘汰要 `opendir` + 逐文件 `stat`。打开 720 项的大媒体库等于数百次全目录扫描。
 *     现在必须是每 `checkEveryDownloads` 次下载才扫一次。
 *  2. **淘汰的扫描代价**：旧实现删一个文件就重新列一次目录（一次淘汰最坏 O(n²) 次
 *     opendir+stat）。现在必须只扫一次。
 *  3. **淘汰必须真的生效**：文件数要压回上限内，且**保留最近写入的**（LRU）。
 *  4. **淘汰不在全局锁内**：旧实现把目录 I/O 放在取图请求共用的那把锁里，
 *     会连带卡住"命中缓存"这种本该毫秒返回的路径。现在淘汰走独立锁
 *     （结构上保证，见 `image_cache.h` 的线程与锁说明）。
 *  5. **未安装下载器必须明确报错**，不能静默返回空路径。
 *  6. **并发请求同一 URL 只下载一次**（在途去重），且等待方不是轮询。
 *
 * Build (from repo root):
 *   g++ -std=c++17 -pthread -I native/core native/core/tests/test_image_cache.cpp \
 *       native/core/image_cache.cpp -o test_image_cache
 */

#include "image_cache.h"

#include <chrono>
#include <cstddef>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/stat.h>
#endif

namespace {

namespace fs = std::filesystem;

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

/**
 * 造一个唯一的临时缓存目录。
 *
 * 用 `std::filesystem` 而不是 POSIX `mkdtemp`：force-build.ps1 在 Windows 上也要能编过。
 */
std::string MakeTempCacheDir()
{
    static std::mutex mutex;
    static int counter = 0;
    int n = 0;
    {
        std::lock_guard<std::mutex> lock(mutex);
        n = counter++;
    }
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path dir = fs::temp_directory_path() /
                         ("jellyfin_imgcache_" + std::to_string(stamp) + "_" + std::to_string(n));
    std::error_code ec;
    fs::create_directories(dir, ec);
    return dir.string();
}

void RemoveDir(const std::string &dir)
{
    std::error_code ec;
    fs::remove_all(dir, ec);
}

bool FileExists(const std::string &path)
{
    std::error_code ec;
    return fs::exists(path, ec);
}

/** 缓存目录里的 `.img` 文件数（`.tmp` 不算） */
std::size_t CountImgFiles(const std::string &dir)
{
    std::size_t count = 0;
    std::error_code ec;
    for (const auto &entry : fs::directory_iterator(dir, ec)) {
        const std::string name = entry.path().filename().string();
        if (name.size() > 4 && name.compare(name.size() - 4, 4, ".img") == 0) {
            ++count;
        }
    }
    return count;
}

#if !defined(_WIN32)
/**
 * 设置文件的 mtime（秒）。
 *
 * 为什么需要：`ImageCache` 的 LRU 判据是 `stat().st_mtime`，而它只到秒 ——
 * 同一个测试里连续写几个文件，mtime 全落在同一秒，排序会退化成按路径。
 * 这里显式把 mtime 拉开，才能断言"删的是最久未写的那个"。
 */
void SetMtime(const std::string &path, long long seconds)
{
    struct timespec times[2];
    times[0].tv_sec = static_cast<time_t>(seconds);
    times[0].tv_nsec = 0;
    times[1].tv_sec = static_cast<time_t>(seconds);
    times[1].tv_nsec = 0;
    utimensat(AT_FDCWD, path.c_str(), times, 0);
}
#endif

/** 记录调用次数的假下载器（线程安全：并发去重用例会多线程打进来） */
struct FakeDownloader {
    std::mutex mutex;
    int calls = 0;
    long long delayMs = 0;
    std::string body = "FAKE-IMAGE-BYTES";

    jellyfin::ImageDownloadFn Make()
    {
        return [this](const std::string & /*url*/, const jellyfin::HttpHeaders & /*headers*/,
                      std::string &out, std::string & /*error*/) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                ++calls;
            }
            if (delayMs > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
            }
            out = body;
            return true;
        };
    }

    int CallCount()
    {
        std::lock_guard<std::mutex> lock(mutex);
        return calls;
    }
};

jellyfin::HttpHeaders AuthHeaders(const std::string &token = "token-A")
{
    return jellyfin::HttpHeaders{{"Authorization", token}};
}

/**
 * 把一个用例的环境准备好：独立目录 + 干净状态 + 假下载器。
 *
 * 注意 `setCacheDirectory()` 会重置下载计数，`clear()` 会清空目录 ——
 * 单例跨用例复用，必须每个用例都重置。
 */
std::string PrepareCase(FakeDownloader &fake, const jellyfin::ImageCache::Limits &limits)
{
    auto &cache = jellyfin::ImageCache::instance();
    const std::string dir = MakeTempCacheDir();
    cache.setCacheDirectory(dir);
    cache.clear();
    cache.setLimits(limits);
    cache.setDownloader(fake.Make());
    return dir;
}

void TestDownloadThenHitCache()
{
    FakeDownloader fake;
    const std::string dir = PrepareCase(fake, jellyfin::ImageCache::Limits{});
    auto &cache = jellyfin::ImageCache::instance();

    std::string error;
    const std::string first = cache.getOrDownload("http://s/Items/a/Images/Primary", AuthHeaders(), error);
    Expect(!first.empty() && error.empty(), "首次取图返回本地路径", error);
    Expect(FileExists(first), "首次取图已落盘", first);
    Expect(fake.CallCount() == 1, "首次取图下载了一次",
           "calls=" + std::to_string(fake.CallCount()));

    error.clear();
    const std::string second = cache.getOrDownload("http://s/Items/a/Images/Primary", AuthHeaders(), error);
    Expect(second == first, "再次取图命中同一路径", second);
    Expect(fake.CallCount() == 1, "命中缓存不再下载",
           "calls=" + std::to_string(fake.CallCount()));

    // 不同令牌必须落到不同缓存键：否则换账号后会命中上一个账号的图。
    error.clear();
    const std::string other = cache.getOrDownload("http://s/Items/a/Images/Primary",
                                                 AuthHeaders("token-B"), error);
    Expect(other != first, "不同凭据不共用缓存条目", other);
    Expect(fake.CallCount() == 2, "不同凭据会重新下载",
           "calls=" + std::to_string(fake.CallCount()));

    RemoveDir(dir);
}

void TestFailuresAreExplicit()
{
    auto &cache = jellyfin::ImageCache::instance();
    const std::string dir = MakeTempCacheDir();
    cache.setCacheDirectory(dir);
    cache.clear();
    cache.setLimits(jellyfin::ImageCache::Limits{});

    std::string error;
    cache.setDownloader(nullptr);
    const std::string noDownloader = cache.getOrDownload("http://s/img", AuthHeaders(), error);
    Expect(noDownloader.empty(), "未安装下载器时返回空路径");
    Expect(error.find("not installed") != std::string::npos,
           "未安装下载器时给出明确原因（不静默）", error);

    FakeDownloader fake;
    cache.setDownloader(fake.Make());
    error.clear();
    const std::string emptyUrl = cache.getOrDownload("", AuthHeaders(), error);
    Expect(emptyUrl.empty() && error == "empty image url", "空 URL 明确报错", error);

    // 未设目录：也必须明确报错，而不是返回空路径让人以为是"图片不存在"。
    cache.setCacheDirectory("");
    error.clear();
    const std::string noDir = cache.getOrDownload("http://s/img", AuthHeaders(), error);
    Expect(noDir.empty() && error.find("directory not set") != std::string::npos,
           "未设置缓存目录时明确报错", error);

    cache.setCacheDirectory(dir);
    RemoveDir(dir);
}

void TestConcurrentRequestsDownloadOnce()
{
    FakeDownloader fake;
    fake.delayMs = 150; // 撑开并发窗口，让所有线程都落在"下载中"
    const std::string dir = PrepareCase(fake, jellyfin::ImageCache::Limits{});
    auto &cache = jellyfin::ImageCache::instance();

    constexpr int kThreads = 8;
    std::vector<std::string> paths(kThreads);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&cache, &paths, i]() {
            std::string error;
            paths[i] = cache.getOrDownload("http://s/Items/a/Images/Primary", AuthHeaders(), error);
        });
    }
    for (auto &t : threads) {
        t.join();
    }

    bool allSame = true;
    for (int i = 0; i < kThreads; ++i) {
        if (paths[i].empty() || paths[i] != paths[0]) {
            allSame = false;
        }
    }
    Expect(allSame, "并发取同一张图都拿到同一路径");
    Expect(fake.CallCount() == 1, "并发取同一张图只下载一次（在途去重）",
           "calls=" + std::to_string(fake.CallCount()));

    RemoveDir(dir);
}

/**
 * 核心回归：淘汰的触发频率。
 *
 * 断言"8 次下载恰好触发 2 次目录扫描（每 4 次一次）"。
 * 旧实现是每下载一张图就扫一次 → 这里会得到 8，用例失败。
 */
void TestEvictScanIsThrottled()
{
    FakeDownloader fake;
    jellyfin::ImageCache::Limits limits;
    limits.checkEveryDownloads = 4;
    limits.maxFiles = 1000; // 不真的触发删除，只看扫描次数
    limits.maxBytes = 1024ull * 1024ull * 1024ull;
    const std::string dir = PrepareCase(fake, limits);
    auto &cache = jellyfin::ImageCache::instance();

    const std::size_t before = cache.evictScanCount();
    for (int i = 0; i < 8; ++i) {
        std::string error;
        cache.getOrDownload("http://s/img/" + std::to_string(i), AuthHeaders(), error);
    }
    const std::size_t scans = cache.evictScanCount() - before;
    Expect(scans == 2, "每 checkEveryDownloads 次下载才扫一次缓存目录",
           "8 次下载实际扫描 " + std::to_string(scans) + " 次（期望 2）");
    Expect(fake.CallCount() == 8, "8 张不同图各下载一次",
           "calls=" + std::to_string(fake.CallCount()));

    RemoveDir(dir);
}

#if !defined(_WIN32)
/**
 * 淘汰必须把文件数压回上限内。
 *
 * 为什么标 POSIX：`ListCacheFiles()` 在 Windows 上是空实现（本工程只把 Windows
 * 当主机单测环境），淘汰不会真的删文件，这条断言在那边没有意义。
 */
void TestEvictionKeepsUnderLimits()
{
    FakeDownloader fake;
    jellyfin::ImageCache::Limits limits;
    limits.maxFiles = 5;
    limits.checkEveryDownloads = 1; // 每次下载都检查，便于精确构造
    limits.maxBytes = 1024ull * 1024ull * 1024ull;
    const std::string dir = PrepareCase(fake, limits);
    auto &cache = jellyfin::ImageCache::instance();

    for (int i = 0; i < 9; ++i) {
        std::string error;
        cache.getOrDownload("http://s/img/" + std::to_string(i), AuthHeaders(), error);
    }

    const std::size_t count = CountImgFiles(dir);
    Expect(count <= 5, "淘汰后缓存文件数回到上限内",
           "实际 " + std::to_string(count) + " 个（上限 5）");
    Expect(count == 5, "淘汰只删到刚好不超限（不多删）",
           "实际 " + std::to_string(count) + " 个");

    RemoveDir(dir);
}

/**
 * 淘汰必须按 LRU 删：最久未写的先走。
 *
 * 旧实现虽然也删，但删法是"每删一个重新列一次目录"；本用例同时守住
 * "删对了人"这条语义（改 O(n²) 时很容易顺手改错顺序）。
 */
void TestEvictionDropsOldestFirst()
{
    FakeDownloader fake;
    jellyfin::ImageCache::Limits limits;
    limits.maxFiles = 2;
    limits.checkEveryDownloads = 1;
    limits.maxBytes = 1024ull * 1024ull * 1024ull;
    const std::string dir = PrepareCase(fake, limits);
    auto &cache = jellyfin::ImageCache::instance();

    std::string error;
    const std::string pathA = cache.getOrDownload("http://s/img/A", AuthHeaders(), error);
    const std::string pathB = cache.getOrDownload("http://s/img/B", AuthHeaders(), error);
    Expect(FileExists(pathA) && FileExists(pathB), "上限内的两张图都在");

    // 把 A 的 mtime 拉到最旧（基准取"过去一小时"，保证 C 写入时的 now 一定更新）。
    const long long base = static_cast<long long>(std::chrono::system_clock::to_time_t(
                               std::chrono::system_clock::now())) -
                           3600;
    SetMtime(pathA, base + 100);
    SetMtime(pathB, base + 200);

    const std::string pathC = cache.getOrDownload("http://s/img/C", AuthHeaders(), error);

    Expect(!FileExists(pathA), "淘汰删掉最久未写的那张（A）");
    Expect(FileExists(pathB), "淘汰保留较新的（B）");
    Expect(FileExists(pathC), "淘汰保留刚写入的（C）");
    Expect(CountImgFiles(dir) == 2, "淘汰后恰好剩上限个文件",
           "实际 " + std::to_string(CountImgFiles(dir)) + " 个");

    RemoveDir(dir);
}
#endif // !_WIN32

void TestClearRemovesEverything()
{
    FakeDownloader fake;
    const std::string dir = PrepareCase(fake, jellyfin::ImageCache::Limits{});
    auto &cache = jellyfin::ImageCache::instance();

    std::string error;
    cache.getOrDownload("http://s/img/1", AuthHeaders(), error);
    cache.getOrDownload("http://s/img/2", AuthHeaders(), error);
    Expect(CountImgFiles(dir) == 2, "清空前目录里有 2 个缓存文件",
           "实际 " + std::to_string(CountImgFiles(dir)) + " 个");

    cache.clear();
    Expect(CountImgFiles(dir) == 0, "clear() 后缓存目录已清空",
           "实际 " + std::to_string(CountImgFiles(dir)) + " 个");

    // clear() 后必须能继续正常取图（不能把 pending 卡死）。
    error.clear();
    const std::string again = cache.getOrDownload("http://s/img/1", AuthHeaders(), error);
    Expect(!again.empty() && FileExists(again), "clear() 之后仍能正常取图", error);

    RemoveDir(dir);
}

} // namespace

int main()
{
    std::cout << "== ImageCache 主机单测 ==\n";
    TestDownloadThenHitCache();
    TestFailuresAreExplicit();
    TestConcurrentRequestsDownloadOnce();
    TestEvictScanIsThrottled();
#if !defined(_WIN32)
    TestEvictionKeepsUnderLimits();
    TestEvictionDropsOldestFirst();
#endif
    TestClearRemovesEverything();

    jellyfin::ImageCache::instance().setDownloader(nullptr);

    if (gFailures == 0) {
        std::cout << "All image cache tests passed\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed\n";
    return 1;
}
