#ifndef JELLYFIN_PLAYER_LOG_H
#define JELLYFIN_PLAYER_LOG_H

#include <string>

namespace jellyfin {
namespace player {

/**
 * 诊断日志注入点。
 *
 * 与 `SetRangeFetcher`（取流注入）同样的思路：本模块**自包含、不依赖任何具体日志实现**
 * （移植到别的工程时不必带上 hilog），由宿主把日志接到自己的输出上。未注入时日志被丢弃。
 *
 * 为什么需要它：软解"卡住不动"这类问题必须能定位到**卡在哪一步**
 * （取流 / 送包 / 收帧 / swscale）。设备上实测过一次"解到第 10 帧后某次拉帧 20 秒不返回"，
 * 当时软解会话内部没有任何耗时日志，只能靠猜；有了注入点就能把每一段的耗时打出来。
 */
using PlayerLogFn = void (*)(const char *message);

/** 注入日志实现（传 nullptr 表示关闭；应尽早调用一次） */
void SetPlayerLogFn(PlayerLogFn fn);

/** 写一条诊断日志（未注入时为 no-op） */
void PlayerLog(const std::string &message);

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_LOG_H */
