#include "player_log.h"

#include <cstdarg>
#include <cstdio>

#if defined(JELLYFIN_HAS_FFMPEG)
extern "C" {
#include <libavutil/log.h>
}
#endif

namespace jellyfin {
namespace player {
namespace {

PlayerLogFn g_logFn = nullptr;

#if defined(JELLYFIN_HAS_FFMPEG)
const char *LevelName(int level)
{
    if (level <= AV_LOG_FATAL) {
        return "fatal";
    }
    if (level <= AV_LOG_ERROR) {
        return "error";
    }
    if (level <= AV_LOG_WARNING) {
        return "warn";
    }
    return "info";
}

/**
 * 把 FFmpeg 自己的日志接到宿主日志上。
 *
 * 为什么必须有：解码器**打不开**时（例如鸿蒙侧没有该编码的编解码器、bitstream filter
 * 缺失、宽高非法），FFmpeg 只会把原因写进它自己的日志（`av_log`），而本工程此前
 * **没有安装 av_log 回调**，于是那些原因连一个字节都到不了 hilog ——
 * 设备上只能看到"打开失败"四个字，无法判断是哪种原因。
 * 只转发 warning 及以上（info/debug 太吵），并加上 `ffmpeg[level]` 前缀便于过滤。
 */
void AvLogBridge(void *avcl, int level, const char *fmt, va_list vl)
{
    (void)avcl;
    if (level > AV_LOG_WARNING) {
        return;
    }
    char buf[512] = {0};
    vsnprintf(buf, sizeof(buf), fmt, vl);
    std::string text(buf);
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
    }
    PlayerLog(std::string("ffmpeg[") + LevelName(level) + "] " + text);
}
#endif

} // namespace

void SetPlayerLogFn(PlayerLogFn fn)
{
    g_logFn = fn;
#if defined(JELLYFIN_HAS_FFMPEG)
    // 注入日志的同时装上 FFmpeg 的日志桥（只装一次即可，重复设置无副作用）
    if (fn != nullptr) {
        av_log_set_callback(AvLogBridge);
    }
#endif
}

void PlayerLog(const std::string &message)
{
    // 注意：软解相关的调用分布在多条线程上（宿主工作线程、预取线程），
    // 这里只读一个函数指针，不引入锁 —— 注入发生在启动阶段，之后不再改动。
    if (g_logFn != nullptr) {
        g_logFn(message.c_str());
    }
}

} // namespace player
} // namespace jellyfin
