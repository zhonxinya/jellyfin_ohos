#include "image_cache.h"

// 本文件刻意**不**构造 HttpClient：下载实现由宿主注入（见 ImageDownloadFn 的说明），
// 因此 core 的图片缓存不依赖 HTTP/TLS 实现，可在主机上零依赖单测。
#include "http_client.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sys/stat.h>
#include <utility>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#else
#include <dirent.h>
#include <unistd.h>
#endif

namespace jellyfin {
namespace {

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

/**
 * 缓存文件是否存在。
 *
 * 用 `stat` 而不是 `ifstream`：本工程对 fd 数量敏感（大媒体库滚图时 fd 逼近上限，
 * 见 napi 里提升 RLIMIT_NOFILE 的说明），而 `stat` 不占 fd。
 */
bool FileExists(const std::string &path)
{
#if defined(_WIN32)
    struct _stat st {};
    return _stat(path.c_str(), &st) == 0 && (st.st_mode & _S_IFREG) != 0;
#else
    struct stat st {};
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
#endif
}

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
    {
        std::lock_guard<std::mutex> lock(mutex_);
        cacheDir_ = dir;
        // 换目录后旧的 pending 记录不再有意义；下载计数也一并归零，
        // 否则上一个目录的下载次数会决定新目录第一次淘汰的时机。
        pending_.clear();
        downloadsSinceEvict_ = 0;
    }
    pendingCv_.notify_all();
}

std::string ImageCache::cacheDirectory() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return cacheDir_;
}

void ImageCache::setDownloader(ImageDownloadFn fn)
{
    std::lock_guard<std::mutex> lock(mutex_);
    downloader_ = std::move(fn);
}

void ImageCache::setLimits(const Limits &limits)
{
    std::lock_guard<std::mutex> lock(mutex_);
    limits_ = limits;
}

ImageCache::Limits ImageCache::limits() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return limits_;
}

std::size_t ImageCache::evictScanCount() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return evictScans_;
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

std::string ImageCache::filePathForKey(const std::string &dir, const std::string &key)
{
    return dir + "/" + key + ".img";
}

void ImageCache::ensureDirAt(const std::string &dir)
{
    if (dir.empty()) {
        return;
    }
#if defined(_WIN32)
    _mkdir(dir.c_str());
#else
    mkdir(dir.c_str(), 0755);
#endif
}

void ImageCache::evictIfNeeded()
{
    // 目录级 I/O：与 clear() 串行化，但**不**占 mutex_ ——
    // 占着它会把所有取图请求（命中缓存、抢下载权）一起卡住。
    std::lock_guard<std::mutex> evictLock(evictMutex_);

    std::string dir;
    Limits lim;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        dir = cacheDir_;
        lim = limits_;
        if (!dir.empty()) {
            ++evictScans_;
        }
    }
    if (dir.empty()) {
        return;
    }

    auto files = ListCacheFiles(dir);
    size_t total = 0;
    for (const auto &f : files) {
        total += f.size;
    }
    if (files.size() <= lim.maxFiles && total <= lim.maxBytes) {
        return;
    }

    // 一次列目录拿到全部 (path, size, mtime)，按"最久未写"排序后**单趟**删除。
    //
    // 旧实现在删除循环里每删一个文件就重新列一次目录，一次淘汰最坏是 O(n²) 次
    // opendir+stat；叠加"每下载一张图就淘汰一次"与"在全局锁内执行"，大媒体库滚图时
    // 表现为所有取图请求一起变慢。
    //
    // 已知取舍：这里的 mtime 是**写入**时间，不是访问时间 —— 所以"很久以前下载、
    // 但刚刚才浏览到"的图会排在前面。实际影响有限（用户浏览的多半是刚下载的），
    // 要更准就得在命中缓存时 touch 文件，那会给命中路径加一次写系统调用。
    std::sort(files.begin(), files.end(), [](const CacheFile &a, const CacheFile &b) {
        if (a.mtime != b.mtime) {
            return a.mtime < b.mtime;
        }
        // mtime 只到秒：同一秒内写入的文件用路径做稳定次序，保证结果可复现。
        return a.path < b.path;
    });

    size_t remaining = files.size();
    for (const auto &f : files) {
        if (remaining <= lim.maxFiles && total <= lim.maxBytes) {
            break;
        }
        if (std::remove(f.path.c_str()) == 0) {
            total = total > f.size ? total - f.size : 0;
            --remaining;
        }
        // 删除失败（例如文件被占用）时不计入 remaining：宁可多试几个，
        // 也不要"以为删掉了"就提前收手而让缓存继续超限。仍超限则留给下一次检查。
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

    // 在锁内把需要的状态拷出来：之后全程用局部量，绝不在锁外读成员。
    std::string dir;
    ImageDownloadFn downloader;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        dir = cacheDir_;
        downloader = downloader_;
    }
    if (dir.empty()) {
        error = "image cache directory not set";
        return {};
    }
    if (!downloader) {
        // 不静默返回空路径：宿主忘记安装下载实现时必须一眼看出原因
        // （见 image_cache_http.h 的说明）。
        error = "image downloader not installed";
        return {};
    }

    const std::string key = cacheKey(url, headers);
    const std::string path = filePathForKey(dir, key);

    // 命中缓存直接返回；未命中则由**抢到下载权**的那个线程负责下载，
    // 其余线程等它完成。`claimed` 是本线程是否抢到下载权的唯一判据。
    bool claimed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (FileExists(path)) {
            return path;
        }
        if (pending_.count(key) == 0) {
            pending_[key] = true;
            claimed = true;
        }
    }

    // 没抢到下载权：等下载方完成。
    //
    // 旧实现是 100ms × 30 的轮询：至少白等 100ms，且整个等待期都占着调用线程
    // （那是 libuv 线程池的 worker，见 napi 的 RunAsync），大媒体库滚图时会把 worker 占满。
    // 现在用条件变量：下载方一完成（成功落盘 / 失败清 pending）立即唤醒 ——
    // 成功即返回路径，失败立刻失败，不用等满超时。
    if (!claimed) {
        bool completed = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            completed = pendingCv_.wait_for(lock, std::chrono::seconds(3), [this, &key] {
                return pending_.find(key) == pending_.end();
            });
        }
        if (FileExists(path)) {
            return path;
        }
        error = completed ? "image download failed in a concurrent request"
                          : "image download timed out waiting for a concurrent request";
        return {};
    }

    // 真正要写盘了才建目录（mkdir 幂等，成本可忽略）：
    // 命中缓存与等待路径完全不碰文件系统写操作。
    ensureDirAt(dir);

    std::string body;
    std::string downloadError;
    if (!downloader(url, headers, body, downloadError)) {
        error = downloadError.empty() ? "image download failed" : downloadError;
        finishDownload(key);
        return {};
    }
    if (body.empty()) {
        error = "empty image body";
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
        out.write(body.data(), static_cast<std::streamsize>(body.size()));
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
    bool shouldEvict = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_.erase(key);
        ++downloadsSinceEvict_;
        if (downloadsSinceEvict_ >= limits_.checkEveryDownloads) {
            downloadsSinceEvict_ = 0;
            shouldEvict = true;
        }
    }
    // 先唤醒等同一张图的其他请求（它们只要文件在就立刻返回）。
    pendingCv_.notify_all();
    if (shouldEvict) {
        // 淘汰在锁外执行：它是目录级 I/O，绝不能占着 mutex_。
        evictIfNeeded();
    }
}

void ImageCache::clear()
{
    std::string dir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        dir = cacheDir_;
        pending_.clear();
        downloadsSinceEvict_ = 0;
    }
    pendingCv_.notify_all();
    if (dir.empty()) {
        return;
    }

    // 目录级 I/O 同样放到锁外：清缓存要删几百个文件，占着 mutex_ 会把取图请求一起卡住。
    std::lock_guard<std::mutex> evictLock(evictMutex_);

    // 不能只用 ListCacheFiles：它会跳过 `.tmp`（进行中的临时文件），
    // 而清除缓存时必须把中断残留的临时文件也一并删掉，否则占用会持续累积。
#if !defined(_WIN32)
    DIR *d = opendir(dir.c_str());
    if (d != nullptr) {
        while (dirent *ent = readdir(d)) {
            const std::string name = ent->d_name;
            if (name == "." || name == "..") {
                continue;
            }
            std::remove((dir + "/" + name).c_str());
        }
        closedir(d);
    }
#else
    for (const auto &f : ListCacheFiles(dir)) {
        std::remove(f.path.c_str());
    }
#endif
}

} // namespace jellyfin
