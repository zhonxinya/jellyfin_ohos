#ifndef JELLYFIN_CORE_IMAGE_CACHE_H
#define JELLYFIN_CORE_IMAGE_CACHE_H

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

    /** Download (or return cached) file path for url. Empty on failure. */
    std::string getOrDownload(const std::string &url, std::string &error);

    void clear();

private:
    ImageCache() = default;

    std::string cacheKey(const std::string &url) const;
    std::string filePathForKey(const std::string &key) const;
    void ensureDir() const;
    void evictIfNeeded();

    mutable std::mutex mutex_;
    std::string cacheDir_;
    std::unordered_map<std::string, bool> pending_;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_IMAGE_CACHE_H */
