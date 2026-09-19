#include "player_log.h"

namespace jellyfin {
namespace player {
namespace {

PlayerLogFn g_logFn = nullptr;

} // namespace

void SetPlayerLogFn(PlayerLogFn fn)
{
    g_logFn = fn;
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
