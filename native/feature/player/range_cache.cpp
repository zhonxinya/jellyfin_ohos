#include "range_cache.h"

#include "range_fetcher.h"

#include <algorithm>
#include <cstring>

namespace jellyfin {
namespace player {

RangeCache::RangeCache(std::string url, int64_t chunkBytes)
    : url_(std::move(url)), chunk_(chunkBytes > 0 ? chunkBytes : 1024 * 1024)
{
}

int64_t RangeCache::probe()
{
    lastReqStart_ = 0;
    lastReqEnd_ = chunk_ - 1;
    const RangeResponse resp = FetchRange(url_, 0, chunk_ - 1);
    if (resp.status >= 400 || resp.body.empty()) {
        // 服务器可能完全不支持 Range：退回整段请求
        lastReqStart_ = 0;
        lastReqEnd_ = -1;
        const RangeResponse plain = FetchRange(url_, 0, -1);
        if (plain.status >= 400 || plain.body.empty()) {
            return 0;
        }
        bytesFetched_ += static_cast<int64_t>(plain.body.size());
        cache_.assign(plain.body.begin(), plain.body.end());
        cacheStart_ = 0;
        size_ = static_cast<int64_t>(cache_.size());
        return size_;
    }
    bytesFetched_ += static_cast<int64_t>(resp.body.size());
    cache_.assign(resp.body.begin(), resp.body.end());
    cacheStart_ = 0;
    if (resp.status == 200) {
        // 服务器忽略了 Range：这就是整片内容
        size_ = static_cast<int64_t>(cache_.size());
    } else if (static_cast<int64_t>(cache_.size()) < chunk_) {
        // 206 但返回不足一个 chunk：说明已到文件末尾，可据此确定长度
        size_ = static_cast<int64_t>(cache_.size());
    }
    return size_;
}

 bool RangeCache::inCache(int64_t pos) const
{
    return !cache_.empty() && pos >= cacheStart_ &&
           pos < cacheStart_ + static_cast<int64_t>(cache_.size());
}

bool RangeCache::fillCache(int64_t pos, std::string &error)
{
    if (size_ >= 0 && pos >= size_) {
        return false;
    }
    const int64_t end = (size_ >= 0)
        ? std::min<int64_t>(pos + chunk_ - 1, size_ - 1)
        : pos + chunk_ - 1;
    lastReqStart_ = pos;
    lastReqEnd_ = end;
    const RangeResponse resp = FetchRange(url_, pos, end);
    if (resp.status == 416) {
        // 416 Range Not Satisfiable = 已越过文件末尾 → 这是 EOF，不是错误。
        // （此前的实现把它当作取流失败，会让 libavformat 在末尾收到 EIO）
        size_ = pos;
        return false;
    }
    if (resp.status >= 400 || resp.body.empty()) {
        // 仅当"响应成功（2xx）且确实没有内容"才视为已到末尾；
        // status=0/带 error 表示取流器本身失败（如未注入 RangeFetcher、网络错误），必须报错而非静默 EOF。
        if (resp.status >= 200 && resp.status < 300 && resp.error.empty() && resp.body.empty()) {
            size_ = pos;
            return false;
        }
        if (pos == 0) {
            // 服务器可能不支持 Range：退回整段请求（仅起点可用）
            lastReqStart_ = 0;
            lastReqEnd_ = -1;
            const RangeResponse plain = FetchRange(url_, 0, -1);
            if (plain.status >= 400 || plain.body.empty()) {
                error = plain.error.empty() ? ("取流失败：HTTP " + std::to_string(plain.status))
                                            : ("取流失败：" + plain.error);
                return false;
            }
            bytesFetched_ += static_cast<int64_t>(plain.body.size());
            cache_.assign(plain.body.begin(), plain.body.end());
            cacheStart_ = 0;
            if (size_ < 0) {
                size_ = static_cast<int64_t>(cache_.size());
            }
            return true;
        }
        error = resp.error.empty() ? ("取流失败：HTTP " + std::to_string(resp.status))
                                   : ("取流失败：" + resp.error);
        return false;
    }
    bytesFetched_ += static_cast<int64_t>(resp.body.size());
    cache_.assign(resp.body.begin(), resp.body.end());
    cacheStart_ = pos;
    if (size_ < 0 && resp.status == 200) {
        // 服务器忽略了 Range，返回整片
        size_ = static_cast<int64_t>(cache_.size());
    } else if (size_ < 0 && static_cast<int64_t>(cache_.size()) < chunk_) {
        // 206 且不足一个 chunk：已到末尾
        size_ = pos + static_cast<int64_t>(cache_.size());
    }
    return true;
}

int RangeCache::read(uint8_t *buf, int bufSize, std::string &error)
{
    if (bufSize <= 0) {
        return 0;
    }
    if (size_ >= 0 && pos_ >= size_) {
        return 0;
    }
    if (!inCache(pos_)) {
        if (!fillCache(pos_, error)) {
            // 已知到末尾时不算错误，按 EOF 处理
            if (size_ >= 0 && pos_ >= size_) {
                return 0;
            }
            return -1;
        }
    }
    const int64_t cacheEnd = cacheStart_ + static_cast<int64_t>(cache_.size());
    const int64_t avail = cacheEnd - pos_;
    if (avail <= 0) {
        return 0;
    }
    const int n = static_cast<int>(std::min<int64_t>(bufSize, avail));
    std::memcpy(buf, cache_.data() + static_cast<size_t>(pos_ - cacheStart_), static_cast<size_t>(n));
    pos_ += n;
    return n;
}

int64_t RangeCache::seek(int64_t offset)
{
    if (offset < 0) {
        return -1;
    }
    if (size_ >= 0) {
        offset = std::min(offset, size_);
    }
    pos_ = offset;
    return pos_;
}

} // namespace player
} // namespace jellyfin
