#ifndef JELLYFIN_CORE_IMAGE_CACHE_H
#define JELLYFIN_CORE_IMAGE_CACHE_H

#include "http_client.h"

#include <condition_variable>
#include <cstddef>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>

namespace jellyfin {

/**
 * 图片下载注入点（与 player 的 `SetRangeFetcher` 同一模式）。
 *
 * 为什么注入而不是直接调 `HttpClient`：本类因此**不依赖任何 HTTP/TLS 实现**，
 * 主机单测只需给一个假下载器（见 `native/core/tests/test_image_cache.cpp`），
 * 不必把 mbedTLS 与网络栈拖进单测编译。
 * 宿主在 NAPI 初始化时安装默认实现：`InstallHttpImageDownloader()`
 * （`image_cache_http.h`）。未安装时 `getOrDownload()` 会**明确报错**，
 * 不会静默返回空路径。
 *
 * @param body  输出：图片字节
 * @param error 输出：失败原因（返回 false 时必须非空）
 * @return true 表示成功
 */
using ImageDownloadFn = std::function<bool(const std::string &url, const HttpHeaders &headers,
                                           std::string &body, std::string &error)>;

/**
 * Disk image cache with in-flight download dedup and simple LRU eviction.
 * Limits: 200 MiB / 500 files (aligned with Flutter ImageCacheManager).
 *
 * ## 线程与锁（改动过的重点，别改回去）
 *
 * 本类有两把锁，职责必须分开：
 *  - `mutex_`：只保护内存状态（`cacheDir_` / `pending_` / `downloader_` / 计数器），
 *    临界区里只做 `stat`，**不做目录遍历**；
 *  - `evictMutex_`：串行化"淘汰 / 清空"这类目录级 I/O。
 *
 * 为什么不能只用一把锁：取图请求（命中缓存与抢下载权）都要走 `mutex_`，
 * 而淘汰要 `opendir` + 对每个文件 `stat`。旧实现把淘汰放在 `mutex_` 里、
 * 且**每下载完一张图就做一次**，于是打开大媒体库（720 项）等于数百次全目录扫描
 * 串行阻塞所有取图请求。现在淘汰一律在锁外执行，并按 `Limits::checkEveryDownloads`
 * 降频。
 */
class ImageCache {
public:
    static ImageCache &instance();

    /** 缓存上限与淘汰节奏。默认值与 Flutter 版 `ImageCacheManager` 对齐。 */
    struct Limits {
        /** 磁盘缓存总字节上限 */
        std::size_t maxBytes = 200u * 1024u * 1024u;
        /** 磁盘缓存文件数上限 */
        std::size_t maxFiles = 500;
        /**
         * 每完成多少次下载才扫描一次缓存目录做淘汰。
         *
         * 为什么不是"每次下载后都淘汰"：淘汰是目录级 I/O（`opendir` + 逐文件 `stat`），
         * 每次下载都做一遍，成本会随缓存条目数叠加到每一张图上。
         * 代价是缓存可能短暂超过上限 `checkEveryDownloads - 1` 个条目，
         * 对 200 MiB / 500 文件的量级可以忽略。
         */
        std::size_t checkEveryDownloads = 32;
    };

    void setCacheDirectory(const std::string &dir);
    std::string cacheDirectory() const;

    /**
     * Download (or return cached) file path for url. Empty on failure.
     *
     * @param headers 随请求发送的头部（鉴权用它传递，**不要**把令牌拼进 url）。
     *                头部会参与缓存键计算：同一 URL 配不同凭据不会互相串图，
     *                换令牌后也不会错误命中上一个账号已缓存的图片。
     */
    std::string getOrDownload(const std::string &url, const HttpHeaders &headers,
                              std::string &error);

    /** 清空磁盘缓存（含中断残留的 `.tmp`）。目录级 I/O 在锁外执行。 */
    void clear();

    /** 安装下载实现；未安装时 `getOrDownload()` 明确失败。 */
    void setDownloader(ImageDownloadFn fn);

    /** 调整上限与淘汰节奏（生产用默认值；单测用它压小阈值以构造淘汰场景） */
    void setLimits(const Limits &limits);
    Limits limits() const;

    /**
     * 累计的缓存目录扫描次数（诊断用，只增不减）。
     *
     * 为什么要有这个数：淘汰是目录级 I/O，它的**触发频率**直接决定取图路径的延迟
     * （旧实现是每下载一张图扫一次、且扫法是 O(n²)）。单测用它守住
     * "每 `checkEveryDownloads` 次下载才扫一次"这条约束。
     */
    std::size_t evictScanCount() const;

private:
    ImageCache() = default;

    std::string cacheKey(const std::string &url, const HttpHeaders &headers) const;
    /** 拼接缓存文件路径（`dir` 由调用方在锁内取出后传入，避免在锁外读 `cacheDir_`） */
    static std::string filePathForKey(const std::string &dir, const std::string &key);
    static void ensureDirAt(const std::string &dir);

    /**
     * 扫描缓存目录并按上限淘汰（最久未写的先删）。
     *
     * **必须在锁外调用**：它会做目录级 I/O，由 `evictMutex_` 串行化，
     * 绝不能占着 `mutex_`（那会把所有取图请求一起卡住）。
     */
    void evictIfNeeded();

    /** 释放下载权、唤醒等待者；到达 `checkEveryDownloads` 时在锁外触发淘汰 */
    void finishDownload(const std::string &key);

    mutable std::mutex mutex_;
    /** 串行化"淘汰 / 清空"这类目录级 I/O，与 `mutex_` 分开，避免阻塞取图请求 */
    mutable std::mutex evictMutex_;
    /** 配合 `mutex_`：下载方完成（成功或失败）时唤醒等待同一张图的其他请求 */
    std::condition_variable pendingCv_;
    std::string cacheDir_;
    std::unordered_map<std::string, bool> pending_;
    ImageDownloadFn downloader_;
    Limits limits_;
    /** 距上次目录扫描已完成的下载次数 */
    std::size_t downloadsSinceEvict_ = 0;
    /** 累计的目录扫描次数（诊断量，见 `evictScanCount()`） */
    std::size_t evictScans_ = 0;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_IMAGE_CACHE_H */
