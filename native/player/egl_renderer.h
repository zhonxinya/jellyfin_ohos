#ifndef JELLYFIN_PLAYER_EGL_RENDERER_H
#define JELLYFIN_PLAYER_EGL_RENDERER_H

#include <cstdint>
#include <string>
#include <vector>

namespace jellyfin {
namespace player {

/**
 * 把 RGBA 帧渲染到 XComponent 的 surface（EGL + GLES）。
 *
 * 为什么需要：软解在 CPU 上出帧后必须上屏；用 `Image(PixelMap)` 逐帧刷新既重又易踩生命周期坑，
 * 直接渲染进视频面（surface）才是播放器该有的路径，也是流畅播放的前提。
 *
 * 线程约束：EGL 上下文与 GL 调用必须在**同一线程**内完成（当前由 ArkTS 定时器驱动的
 * 解码循环所在线程负责），不要在别的线程调用这些方法。
 */
class EglRenderer {
public:
    EglRenderer() = default;
    ~EglRenderer();

    EglRenderer(const EglRenderer &) = delete;
    EglRenderer &operator=(const EglRenderer &) = delete;

    /**
     * 绑定 XComponent surface（surfaceId 来自 ArkTS 的 XComponent onLoad）并建立 EGL/GLES 环境。
     * @param requestedWidth/Height XComponent 的像素尺寸（用于 surface 几何未就绪时兜底设置，可传 0）
     */
    bool init(uint64_t surfaceId, std::string &error, int requestedWidth = 0, int requestedHeight = 0);

    /** 上传一帧 RGBA 并绘制、交换缓冲（宽高等比铺满，保持画面比例） */
    bool renderRgba(const uint8_t *rgba, int width, int height, std::string &error);

    /**
     * 从**当前渲染缓冲**回读像素（glReadPixels）。
     * 用于验证"确实渲染出来了"——不依赖系统截图是否含 surface 内容。
     */
    bool readbackRgba(std::vector<uint8_t> &out, int &width, int &height, std::string &error);

    void destroy();
    bool isReady() const { return ready_; }

private:
    bool buildProgram(std::string &error);

    uint64_t surfaceId_ = 0;
    void *nativeWindow_ = nullptr;
    void *display_ = nullptr;   // EGLDisplay
    void *context_ = nullptr;   // EGLContext
    void *surface_ = nullptr;   // EGLSurface
    unsigned int program_ = 0;
    unsigned int texture_ = 0;
    unsigned int vbo_ = 0;
    int attribPos_ = -1;
    int attribUv_ = -1;
    int uniformTex_ = -1;
    int surfaceWidth_ = 0;
    int surfaceHeight_ = 0;
    int requestedWidth_ = 0;
    int requestedHeight_ = 0;
    bool ready_ = false;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_EGL_RENDERER_H */
