#ifndef JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H
#define JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H

#include <cstdint>
#include <string>

namespace jellyfin {
namespace player {

/**
 * HTTP Range 分页缓存：把"顺序读字节"翻译成按需的 Range 请求，并缓存最近一块。
 *
 * 设计要点（也是它能整目录移植的原因）：
 *  - 只依赖 `range_fetcher.h` 的取流回调，不含任何 HTTP/TLS/平台代码，可在主机上单测；
 *  - 供 libavformat 的自定义 AVIO 使用：`read()`/`seek()` 语义与文件流一致；
 *  - 服务器支持 Range（206）时按 chunk 拉取，边下边解；不支持时退化为整段请求；
 *  - 服务器返回 200（忽略 Range）时把 body 当作整片，从而确定总长度。
 */
class RangeCache {
public:
    /**
     * @param url        完整地址（含鉴权参数；本类不关心鉴权方式）
     * @param chunkBytes 单次 Range 请求字节数，默认 1 MiB —— 请求过碎会拖慢解码，过大则首帧等待变长
     */
    explicit RangeCache(std::string url, int64_t chunkBytes = 1024 * 1024);

    /**
     * 预取首个分片并尽力推断总长度。
     * @return 已知总长度（>0）；0 表示取流失败；-1 表示长度未知但可顺序读取（服务器支持 Range）
     */
    int64_t probe();

    /** 已知总长度（-1 表示未知） */
    int64_t size() const { return size_; }

    /** 已通过网络取到的字节数（诊断用） */
    int64_t bytesFetched() const { return bytesFetched_; }

    /** 当前读取位置 */
    int64_t position() const { return pos_; }

    /** 读取最多 bufSize 字节；返回实际字节数，0 表示 EOF，-1 表示错误（error 非空） */
    int read(uint8_t *buf, int bufSize, std::string &error);

    /** 定位到 offset（不预取，下次 read 时按需拉取）；失败返回 -1 */
    int64_t seek(int64_t offset);

    /** 最近一次实际发出的 Range 请求（含端字节），用于诊断与单测断言 */
    int64_t lastRequestStart() const { return lastReqStart_; }
    int64_t lastRequestEnd() const { return lastReqEnd_; }

private:
    bool inCache(int64_t pos) const;
    bool fillCache(int64_t pos, std::string &error);

    std::string url_;
    int64_t chunk_;
    std::string cache_;
    int64_t cacheStart_ = 0;
    int64_t pos_ = 0;
    int64_t size_ = -1;
    int64_t bytesFetched_ = 0;
    int64_t lastReqStart_ = -1;
    int64_t lastReqEnd_ = -1;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H */
