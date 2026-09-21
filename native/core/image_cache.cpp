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

std::string ImageCache::cacheKey(const std::string &url, const HttpHeaders &headers) const
{
    // 把鉴权相关头部并入缓存键，避免「同一 URL + 不同令牌」互相串图
    // （换账号/换令牌后仍会命中旧账号的图片缓存）。
    std::string material = url;
    for (const auto &kv : headers) {
        if (kv.second.empty()) {
            continue;
        }
        material += '\n';
        material += kv.first;
        material += ':';
        material += kv.second;
    }
    return HashUrl(material);
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

std::string ImageCache::getOrDownload(const std::string &url, const HttpHeaders &headers,
                                      std::string &error)
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

    const std::string key = cacheKey(url, headers);
    const std::string path = filePathForKey(key);

    // 命中缓存直接返回；未命中则由**抢到下载权**的那个线程负责下载，
    // 其余线程只等待文件出现。`claimed` 是本线程是否抢到下载权的唯一判据。
    bool claimed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ensureDir();
        std::ifstream existing(path, std::ios::binary);
        if (existing.good()) {
            return path;
        }
        if (pending_.count(key) == 0) {
            pending_[key] = true;
            claimed = true;
        }
    }

    // 没抢到下载权：等待另一个线程完成下载。
    //
    // 旧实现是一个 20ms×50 轮的多分支轮询，分支条件互相矛盾（既想独占又想并发），
    // 实际结果是「多个线程同时下载同一张图」。现在语义单一：
    //   - 抢到下载权的线程负责下载；
    //   - 其余线程只等文件出现，超时即放弃（返回空 → 上层显示占位图）。
    // 超时上限约 3 秒（30 × 100ms），足够覆盖大图下载，又不会长时间占住调用线程。
    if (!claimed) {
        for (int i = 0; i < 30; ++i) {
#if !defined(_WIN32)
            usleep(100000);
#endif
            std::ifstream existing(path, std::ios::binary);
            if (existing.good()) {
                return path;
            }
        }
        error = "image download timed out waiting for concurrent request";
        return {};
    }

    HttpClient http;
    http.setReadTimeoutSec(60);
    HttpHeaders requestHeaders = headers;
    if (requestHeaders.find("Accept") == requestHeaders.end()) {
        requestHeaders["Accept"] = "*/*";
    }
    // 凭据只走请求头（见 image_url.cpp 的安全约定）：URL 会进服务端访问日志。
    HttpResponse resp = http.get(url, requestHeaders);
    if (!resp.error.empty() || resp.status < 200 || resp.status >= 300 || resp.body.empty()) {
        error = resp.error.empty() ? ("HTTP " + std::to_string(resp.status)) : resp.error;
        finishDownload(key);
        return {};
    }

    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary);
        if (!out) {
            error = "failed to write cache temp file";
            finishDownload(key);
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

    finishDownload(key);
    return path;
}

void ImageCache::finishDownload(const std::string &key)
{
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.erase(key);
    evictIfNeeded();
}

void ImageCache::clear()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (cacheDir_.empty()) {
        return;
    }
    // 不能只用 ListCacheFiles：它会跳过 `.tmp`（进行中的临时文件），
    // 而清除缓存时必须把中断残留的临时文件也一并删掉，否则占用会持续累积。
#if !defined(_WIN32)
    DIR *d = opendir(cacheDir_.c_str());
    if (d != nullptr) {
        while (dirent *ent = readdir(d)) {
            const std::string name = ent->d_name;
            if (name == "." || name == "..") {
                continue;
            }
            std::remove((cacheDir_ + "/" + name).c_str());
        }
        closedir(d);
    }
#else
    for (const auto &f : ListCacheFiles(cacheDir_)) {
        std::remove(f.path.c_str());
    }
#endif
    pending_.clear();
}

} // namespace jellyfin
