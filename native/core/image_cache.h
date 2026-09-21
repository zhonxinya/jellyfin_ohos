#ifndef JELLYFIN_CORE_IMAGE_CACHE_H
#define JELLYFIN_CORE_IMAGE_CACHE_H

#include "http_client.h"

#include <mutex>
#include <string>
#include <unordered_map>

namespace jellyfin {

/**
 * Disk image cache with in-flight download dedup and simple LRU eviction.
 * Limits: 200 MiB / 500 files (aligned with Flutter ImageCacheManager).
 */
class ImageCache {
public:
    static ImageCache &instance();

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

    void clear();

private:
    ImageCache() = default;

    std::string cacheKey(const std::string &url, const HttpHeaders &headers) const;
    std::string filePathForKey(const std::string &key) const;
    void ensureDir() const;
    void evictIfNeeded();
    /** 释放下载权并触发淘汰（所有退出路径都必须调用，否则该 key 永久卡在 pending） */
    void finishDownload(const std::string &key);

    mutable std::mutex mutex_;
    std::string cacheDir_;
    std::unordered_map<std::string, bool> pending_;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_IMAGE_CACHE_H */
