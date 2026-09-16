#ifndef JELLYFIN_FEATURE_PLAYER_RANGE_FETCHER_H
#define JELLYFIN_FEATURE_PLAYER_RANGE_FETCHER_H

#include <cstdint>
#include <functional>
#include <string>

namespace jellyfin {
namespace player {

/**
 * 取流抽象：`feature/player` 只依赖这个回调，**不依赖任何具体 HTTP 实现**。
 *
 * 为什么这样设计：本模块要能整目录移植到其它项目。宿主（本项目是 `native/napi`，
 * 基于 `native/core` 的 HttpClient，含 mbedTLS/https 与 Jellyfin 鉴权）在启动时注入自己的实现；
 * 换到别的工程时注入 curl / WinHTTP / 平台网络栈即可，软解与渲染代码一行都不用改。
 */
struct RangeResponse {
    /** HTTP 状态码（206/200 表示成功；其余由调用方判断） */
    int status = 0;
    /** 响应体（调用方要求的字节区间） */
    std::string body;
    /** 传输层错误（非空表示请求未能完成） */
    std::string error;
};

/**
 * 按字节区间取数据。
 * @param url   完整地址（应已包含鉴权参数；`feature/player` 不关心鉴权方式）
 * @param start 起始字节（含）
 * @param end   结束字节（含）；传 -1 表示"从 start 到末尾"
 */
using RangeFetchFn = std::function<RangeResponse(const std::string &url, int64_t start, int64_t end)>;

/** 注入取流实现（进程级，一次即可）。未注入时 `soft_decode_session` 会明确报错而不是静默失败。 */
void SetRangeFetcher(RangeFetchFn fn);

/** 当前取流实现是否可用 */
bool HasRangeFetcher();

/**
 * 调用当前取流实现。未注入时返回 status=0 且 error 说明"未注入 RangeFetcher"。
 * （供 feature 内部使用，也便于宿主自测）
 */
RangeResponse FetchRange(const std::string &url, int64_t start, int64_t end);

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_FEATURE_PLAYER_RANGE_FETCHER_H */
