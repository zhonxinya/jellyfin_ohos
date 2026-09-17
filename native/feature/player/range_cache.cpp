#include "range_cache.h"

#include "range_fetcher.h"

#include <algorithm>
#include <chrono>
#include <cstring>

namespace jellyfin {
namespace player {

RangeCache::RangeCache(std::string url, int64_t chunkBytes)
    : url_(std::move(url)), chunk_(chunkBytes > 0 ? chunkBytes : 1024 * 1024)
{
}

RangeCache::~RangeCache()
{
    stopPrefetch();
}

int64_t RangeCache::size() const
{
    std::lock_guard<std::mutex> lock(mtx_);
    return size_;
}

int64_t RangeCache::bytesFetched() const
{
    std::lock_guard<std::mutex> lock(mtx_);
    return bytesFetched_;
}

int64_t RangeCache::position() const
{
    std::lock_guard<std::mutex> lock(mtx_);
    return pos_;
}

int64_t RangeCache::lastRequestStart() const
{
    std::lock_guard<std::mutex> lock(mtx_);
    return lastReqStart_;
}

int64_t RangeCache::lastRequestEnd() const
{
    std::lock_guard<std::mutex> lock(mtx_);
    return lastReqEnd_;
}

int64_t RangeCache::prefetchRequests() const
{
    return prefetchRequests_.load();
}

int64_t RangeCache::probe()
{
    {
        std::lock_guard<std::mutex> lock(mtx_);
        chunks_.clear();
        size_ = -1;
        lastReqStart_ = 0;
        lastReqEnd_ = chunk_ - 1;
    }
    const RangeResponse resp = FetchRange(url_, 0, chunk_ - 1);
    if (resp.status >= 400 || resp.body.empty()) {
        // 服务器可能完全不支持 Range：退回整段请求
        {
            std::lock_guard<std::mutex> lock(mtx_);
            lastReqStart_ = 0;
            lastReqEnd_ = -1;
        }
        const RangeResponse plain = FetchRange(url_, 0, -1);
        if (plain.status >= 400 || plain.body.empty()) {
            return 0;
        }
        std::lock_guard<std::mutex> lock(mtx_);
        bytesFetched_ += static_cast<int64_t>(plain.body.size());
        chunks_.clear();
        chunks_[0] = plain.body;
        size_ = static_cast<int64_t>(plain.body.size());
        return size_;
    }
    std::lock_guard<std::mutex> lock(mtx_);
    bytesFetched_ += static_cast<int64_t>(resp.body.size());
    chunks_.clear();
    chunks_[0] = resp.body;
    if (resp.status == 200) {
        // 服务器忽略了 Range：这就是整片内容
        size_ = static_cast<int64_t>(resp.body.size());
    } else if (static_cast<int64_t>(resp.body.size()) < chunk_) {
        // 206 但返回不足一个 chunk：说明已到文件末尾，可据此确定长度
        size_ = static_cast<int64_t>(resp.body.size());
    }
    return size_;
}

int64_t RangeCache::chunkEndContainingLocked(int64_t pos) const
{
    for (const auto &entry : chunks_) {
        const int64_t start = entry.first;
        const int64_t end = start + static_cast<int64_t>(entry.second.size());
        if (pos >= start && pos < end) {
            return end;
        }
    }
    return -1;
}

int64_t RangeCache::contiguousEndLocked() const
{
    int64_t end = pos_;
    bool advanced = true;
    while (advanced) {
        advanced = false;
        for (const auto &entry : chunks_) {
            const int64_t start = entry.first;
            const int64_t chunkEnd = start + static_cast<int64_t>(entry.second.size());
            if (start <= end && chunkEnd > end) {
                end = chunkEnd;
                advanced = true;
            }
        }
    }
    return end;
}

void RangeCache::evictLocked()
{
    while (static_cast<int64_t>(chunks_.size()) > maxChunks_) {
        auto victim = chunks_.end();
        for (auto it = chunks_.begin(); it != chunks_.end(); ++it) {
            const int64_t end = it->first + static_cast<int64_t>(it->second.size());
            if (end <= pos_) {
                victim = it;
                break;
            }
        }
        if (victim == chunks_.end()) {
            victim = chunks_.begin();
        }
        chunks_.erase(victim);
    }
}

bool RangeCache::fetchIntoLockedRange(int64_t pos, std::string &error, bool countAsPrefetch)
{
    // 注意：调用方**不得持锁** —— FetchRange 是同步网络调用，持锁会连带阻塞读取线程
    int64_t sizeSnapshot = -1;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (size_ >= 0 && pos >= size_) {
            return false;
        }
        sizeSnapshot = size_;
    }
    // 按块对齐请求：预取线程与读取线程于是共用同一批分块，命中率才高
    const int64_t start = (pos / chunk_) * chunk_;
    const int64_t end = (sizeSnapshot >= 0) ? std::min<int64_t>(start + chunk_ - 1, sizeSnapshot - 1)
                                           : start + chunk_ - 1;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        lastReqStart_ = start;
        lastReqEnd_ = end;
    }
    const RangeResponse resp = FetchRange(url_, start, end);
    if (resp.status >= 400 || resp.body.empty()) {
        // 起点处的失败可能是"服务器不支持 Range"：退化为整段请求再试一次
        if (start == 0) {
            std::lock_guard<std::mutex> lock(mtx_);
            lastReqStart_ = 0;
            lastReqEnd_ = -1;
        }
        const RangeResponse plain = (start == 0) ? FetchRange(url_, 0, -1) : resp;
        std::lock_guard<std::mutex> lock(mtx_);
        if (plain.status >= 400 || plain.body.empty()) {
            if (plain.status >= 200 && plain.status < 300 && plain.error.empty() &&
                plain.body.empty()) {
                // 2xx 且确实没有内容 = 已到末尾
                size_ = start;
                return false;
            }
            if (!resp.error.empty()) {
                error = "取流失败：" + resp.error;
            } else if (resp.status == 416) {
                // 416 Range Not Satisfiable = 越过末尾（EOF，不是错误）
                size_ = start;
                return false;
            } else {
                error = plain.error.empty() ? ("取流失败：HTTP " + std::to_string(plain.status))
                                            : ("取流失败：" + plain.error);
            }
            return false;
        }
        bytesFetched_ += static_cast<int64_t>(plain.body.size());
        chunks_.clear();
        chunks_[0] = plain.body;
        size_ = static_cast<int64_t>(plain.body.size());
        if (countAsPrefetch) {
            prefetchRequests_.fetch_add(1);
        }
        return true;
    }
    std::lock_guard<std::mutex> lock(mtx_);
    bytesFetched_ += static_cast<int64_t>(resp.body.size());
    // 服务器忽略 Range（200）时 body 是整片：缓存键应为 0
    const int64_t storeAt = (resp.status == 200) ? 0 : start;
    chunks_[storeAt] = resp.body;
    if (size_ < 0 && resp.status == 200) {
        size_ = static_cast<int64_t>(resp.body.size());
    } else if (size_ < 0 && static_cast<int64_t>(resp.body.size()) < chunk_) {
        size_ = storeAt + static_cast<int64_t>(resp.body.size());
    }
    if (countAsPrefetch) {
        prefetchRequests_.fetch_add(1);
    }
    evictLocked();
    return true;
}

int RangeCache::read(uint8_t *buf, int bufSize, std::string &error)
{
    if (bufSize <= 0) {
        return 0;
    }
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (size_ >= 0 && pos_ >= size_) {
            return 0;
        }
        for (const auto &entry : chunks_) {
            const int64_t start = entry.first;
            const int64_t end = start + static_cast<int64_t>(entry.second.size());
            if (pos_ >= start && pos_ < end) {
                const int n = static_cast<int>(std::min<int64_t>(bufSize, end - pos_));
                std::memcpy(buf, entry.second.data() + static_cast<size_t>(pos_ - start),
                            static_cast<size_t>(n));
                pos_ += n;
                return n;
            }
        }
    }
    // 未命中：同步取流兜底（后台预取没跟上，或 seek 到了尚未预取的位置）
    if (!fetchIntoLockedRange(pos_, error, false)) {
        std::lock_guard<std::mutex> lock(mtx_);
        if (size_ >= 0 && pos_ >= size_) {
            return 0;
        }
        if (error.empty()) {
            error = "读取失败：取流未返回数据";
        }
        return -1;
    }
    std::lock_guard<std::mutex> lock(mtx_);
    for (const auto &entry : chunks_) {
        const int64_t start = entry.first;
        const int64_t end = start + static_cast<int64_t>(entry.second.size());
        if (pos_ >= start && pos_ < end) {
            const int n = static_cast<int>(std::min<int64_t>(bufSize, end - pos_));
            std::memcpy(buf, entry.second.data() + static_cast<size_t>(pos_ - start),
                        static_cast<size_t>(n));
            pos_ += n;
            return n;
        }
    }
    return 0;
}

int64_t RangeCache::seek(int64_t offset)
{
    if (offset < 0) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(mtx_);
    if (size_ >= 0) {
        offset = std::min(offset, size_);
    }
    pos_ = offset;
    return pos_;
}

void RangeCache::startPrefetch(int64_t aheadChunks)
{
    if (running_.load()) {
        return;
    }
    aheadChunks_ = aheadChunks > 0 ? aheadChunks : 8;
    running_.store(true);
    worker_ = std::thread([this]() { prefetchLoop(); });
}

void RangeCache::stopPrefetch()
{
    const bool wasRunning = running_.exchange(false);
    if (worker_.joinable()) {
        worker_.join();
    }
    (void)wasRunning;
}

void RangeCache::prefetchLoop()
{
    while (running_.load()) {
        int64_t next = -1;
        {
            std::lock_guard<std::mutex> lock(mtx_);
            const bool complete = (size_ >= 0 && contiguousEndLocked() >= size_);
            if (!complete) {
                const int64_t target = pos_ + aheadChunks_ * chunk_;
                const int64_t haveEnd = contiguousEndLocked();
                if (haveEnd < target) {
                    next = haveEnd;
                }
            }
        }
        if (next < 0) {
            // 预取够了（或已到末尾）：歇一会儿再看，避免空转吃 CPU
            std::this_thread::sleep_for(std::chrono::milliseconds(30));
            continue;
        }
        std::string error;
        if (!fetchIntoLockedRange(next, error, true)) {
            // 到末尾或取流失败：稍后再试（seek 之后可能又需要数据）
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }
}

} // namespace player
} // namespace jellyfin
