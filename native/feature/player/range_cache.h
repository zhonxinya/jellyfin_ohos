#ifndef JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H
#define JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H

#include <atomic>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <thread>

namespace jellyfin {
namespace player {

/**
 * HTTP Range 分页缓存：把"顺序读字节"翻译成按需的 Range 请求，并缓存**多块**数据。
 *
 * 设计要点（也是它能整目录移植的原因）：
 *  - 只依赖 `range_fetcher.h` 的取流回调，不含任何 HTTP/TLS/平台代码，可在主机上单测；
 *  - 供 libavformat 的自定义 AVIO 使用：`read()`/`seek()` 语义与文件流一致；
 *  - 服务器支持 Range（206）时按 chunk 拉取，边下边解；不支持时退化为整段请求；
 *  - 服务器返回 200（忽略 Range）时把 body 当作整片，从而确定总长度。
 *
 * ## 为什么要有后台预取（`startPrefetch()`）
 *
 * 设备实测（faultlog 主线程栈）：软解逐帧拉取时，`read()` 未命中缓存会走
 * `fillCache()` → `FetchRange()`，也就是**在调用线程（宿主是 UI 线程）上做同步 HTTP**，
 * 一次网络往返足以把主线程阻塞 6 秒以上，系统判 `THREAD_BLOCK_6S`（appfreeze），
 * 界面直接消失。根因不是"取流慢"，而是"取流发生在 UI 线程上"。
 *
 * 因此本类支持启动一个后台线程持续把数据**预取**到读取位置之前：
 * 读取路径通常直接命中缓存、完全不碰网络；只有 seek 到未预取的位置时才会退化为同步取流。
 */
class RangeCache {
public:
    /**
     * @param url        完整地址（含鉴权参数；本类不关心鉴权方式）
     * @param chunkBytes 单次 Range 请求字节数，默认 1 MiB —— 请求过碎会拖慢解码，过大则首帧等待变长
     */
    explicit RangeCache(std::string url, int64_t chunkBytes = 1024 * 1024);
    ~RangeCache();

    RangeCache(const RangeCache &) = delete;
    RangeCache &operator=(const RangeCache &) = delete;

    /**
     * 预取首个分片并尽力推断总长度。
     * @return 已知总长度（>0）；0 表示取流失败；-1 表示长度未知但可顺序读取（服务器支持 Range）
     */
    int64_t probe();

    /** 已知总长度（-1 表示未知） */
    int64_t size() const;

    /** 已通过网络取到的字节数（诊断用） */
    int64_t bytesFetched() const;

    /** 当前读取位置 */
    int64_t position() const;

    /** 读取最多 bufSize 字节；返回实际字节数，0 表示 EOF，-1 表示错误（error 非空） */
    int read(uint8_t *buf, int bufSize, std::string &error);

    /** 定位到 offset（不预取，下次 read 时按需拉取）；失败返回 -1 */
    int64_t seek(int64_t offset);

    /** 最近一次实际发出的 Range 请求（含端字节），用于诊断与单测断言 */
    int64_t lastRequestStart() const;
    int64_t lastRequestEnd() const;

    /**
     * 启动后台预取线程：持续把数据填到读取位置之前。
     * @param aheadChunks 预取保持在读取位置之前的块数（默认 8 块 = 8 MiB）
     */
    void startPrefetch(int64_t aheadChunks = 8);

    /** 停止后台预取线程（幂等；析构时也会调用） */
    void stopPrefetch();

    /** 预取线程累计成功发出的请求数（诊断用） */
    int64_t prefetchRequests() const;

private:
    /** 在已缓存的分块里找到包含 pos 的那块；返回其末尾（不含），未命中返回 -1 */
    int64_t chunkEndContainingLocked(int64_t pos) const;

    /** 已缓存数据的连续末端（从 pos 开始向前推进）；无数据时返回 pos */
    int64_t contiguousEndLocked() const;

    /** 在调用方已释放锁的情况下取一块并存入缓存；失败时返回 false 并给出 error */
    bool fetchIntoLockedRange(int64_t pos, std::string &error, bool countAsPrefetch);

    /** 丢弃离读取位置太远的旧分块，避免无限增长 */
    void evictLocked();

    void prefetchLoop();

    std::string url_;
    int64_t chunk_;

    mutable std::mutex mtx_;
    /** 分块缓存：键为分块起始偏移 */
    std::map<int64_t, std::string> chunks_;
    int64_t pos_ = 0;
    int64_t size_ = -1;
    int64_t bytesFetched_ = 0;
    int64_t lastReqStart_ = -1;
    int64_t lastReqEnd_ = -1;

    /** 保留的最大分块数（超出后丢弃读取位置之后的远块与已读过的旧块） */
    int64_t maxChunks_ = 12;
    int64_t aheadChunks_ = 8;

    std::thread worker_;
    std::atomic<bool> running_{false};
    std::atomic<int64_t> prefetchRequests_{0};
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_FEATURE_PLAYER_RANGE_CACHE_H */
