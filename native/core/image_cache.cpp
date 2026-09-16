#include "image_cache.h"

#include "http_client.h"

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <sys/stat.h>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#else
#include <dirent.h>
#include <unistd.h>
#endif

namespace jellyfin {
namespace {

constexpr size_t kMaxCacheBytes = 200u * 1024u * 1024u;
constexpr size_t kMaxCacheFiles = 500;

// FNV-1a 64-bit — good enough for cache keys without pulling crypto.
std::string HashUrl(const std::string &url)
{
    uint64_t h = 14695981039346656037ull;
    for (unsigned char c : url) {
        h ^= c;
        h *= 1099511628211ull;
    }
    char buf[17];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(h));
    return std::string(buf);
}

struct CacheFile {
    std::string path;
    size_t size = 0;
    long long mtime = 0;
};

#if !defined(_WIN32)
std::vector<CacheFile> ListCacheFiles(const std::string &dir)
{
    std::vector<CacheFile> out;
    DIR *d = opendir(dir.c_str());
    if (d == nullptr) {
        return out;
    }
    while (dirent *ent = readdir(d)) {
        const std::string name = ent->d_name;
        if (name == "." || name == ".." || name.size() < 5) {
            continue;
        }
        if (name.find(".tmp") != std::string::npos) {
            continue;
        }
        const std::string path = dir + "/" + name;
        struct stat st {};
        if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
            continue;
        }
        CacheFile f;
        f.path = path;
        f.size = static_cast<size_t>(st.st_size);
        f.mtime = static_cast<long long>(st.st_mtime);
        out.push_back(f);
    }
    closedir(d);
    return out;
}
#else
std::vector<CacheFile> ListCacheFiles(const std::string & /*dir*/)
{
    return {};
}
#endif

} // namespace

ImageCache &ImageCache::instance()
{
    static ImageCache cache;
    return cache;
}

void ImageCache::setCacheDirectory(const std::string &dir)
{
    std::lock_guard<std::mutex> lock(mutex_);
    cacheDir_ = dir;
}

std::string ImageCache::cacheDirectory() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return cacheDir_;
}

std::string ImageCache::cacheKey(const std::string &url) const
{
    return HashUrl(url);
}

std::string ImageCache::filePathForKey(const std::string &key) const
{
    return cacheDir_ + "/" + key + ".img";
}

void ImageCache::ensureDir() const
{
    if (cacheDir_.empty()) {
        return;
    }
#if defined(_WIN32)
    _mkdir(cacheDir_.c_str());
#else
    mkdir(cacheDir_.c_str(), 0755);
#endif
}

void ImageCache::evictIfNeeded()
{
    if (cacheDir_.empty()) {
        return;
    }
    auto files = ListCacheFiles(cacheDir_);
    size_t total = 0;
    for (const auto &f : files) {
        total += f.size;
    }
    if (files.size() <= kMaxCacheFiles && total <= kMaxCacheBytes) {
        return;
    }
    std::sort(files.begin(), files.end(),
              [](const CacheFile &a, const CacheFile &b) { return a.mtime < b.mtime; });
    for (const auto &f : files) {
        if (files.size() <= kMaxCacheFiles && total <= kMaxCacheBytes) {
            break;
        }
        std::remove(f.path.c_str());
        total = total > f.size ? total - f.size : 0;
        // Approximate count reduction.
        if (!files.empty()) {
            // just continue removing oldest until under limits
        }
        (void)files;
        if (total <= kMaxCacheBytes) {
            // Recheck file count loosely
            auto remaining = ListCacheFiles(cacheDir_);
            if (remaining.size() <= kMaxCacheFiles && total <= kMaxCacheBytes) {
                break;
            }
        }
    }
}

std::string ImageCache::getOrDownload(const std::string &url, std::string &error)
{
    error.clear();
    if (url.empty()) {
        error = "empty image url";
        return {};
    }
    if (cacheDir_.empty()) {
        error = "image cache directory not set";
        return {};
    }

    const std::string key = cacheKey(url);
    const std::string path = filePathForKey(key);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        ensureDir();
        std::ifstream existing(path, std::ios::binary);
        if (existing.good()) {
            return path;
        }
        if (pending_.count(key) != 0) {
            // Another thread is downloading; wait briefly by polling file.
        } else {
            pending_[key] = true;
        }
    }

    // Simple wait loop if another download is in progress.
    for (int i = 0; i < 50; ++i) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            std::ifstream existing(path, std::ios::binary);
            if (existing.good()) {
                return path;
            }
            if (pending_.count(key) == 0) {
                pending_[key] = true;
                break;
            }
            if (i == 0 && pending_[key]) {
                // We own or share the pending flag; first waiter that set it downloads.
            }
        }
#if !defined(_WIN32)
        usleep(20000);
#endif
        std::ifstream existing(path, std::ios::binary);
        if (existing.good()) {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.erase(key);
            return path;
        }
        // Only one download proceeds — check ownership via file absence + pending.
        bool shouldDownload = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (pending_[key]) {
                // Try to claim: use a .lock approach by checking if we're still pending
                // and no file yet. For simplicity, allow concurrent downloads of same URL
                // but write atomically to .tmp then rename.
                shouldDownload = true;
                break;
            }
        }
        if (shouldDownload) {
            break;
        }
    }

    HttpClient http;
    http.setReadTimeoutSec(60);
    HttpHeaders headers;
    headers["Accept"] = "*/*";
    HttpResponse resp = http.get(url, headers);
    if (!resp.error.empty() || resp.status < 200 || resp.status >= 300 || resp.body.empty()) {
        error = resp.error.empty() ? ("HTTP " + std::to_string(resp.status)) : resp.error;
        std::lock_guard<std::mutex> lock(mutex_);
        pending_.erase(key);
        return {};
    }

    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary);
        if (!out) {
            error = "failed to write cache temp file";
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.erase(key);
            return {};
        }
        out.write(resp.body.data(), static_cast<std::streamsize>(resp.body.size()));
    }
#if !defined(_WIN32)
    std::rename(tmp.c_str(), path.c_str());
#else
    std::remove(path.c_str());
    std::rename(tmp.c_str(), path.c_str());
#endif

    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_.erase(key);
        evictIfNeeded();
    }
    return path;
}

void ImageCache::clear()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (cacheDir_.empty()) {
        return;
    }
    auto files = ListCacheFiles(cacheDir_);
    for (const auto &f : files) {
        std::remove(f.path.c_str());
    }
    pending_.clear();
}

} // namespace jellyfin
