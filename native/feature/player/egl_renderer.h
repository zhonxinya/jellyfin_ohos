#ifndef JELLYFIN_PLAYER_EGL_RENDERER_H
#define JELLYFIN_PLAYER_EGL_RENDERER_H

#include <cstdint>
#include <string>
#include <vector>

namespace jellyfin {
namespace player {

/**
 * 画面缩放模式。
 *
 * 为什么渲染器要自己管比例，而不是全靠宿主把 XComponent 调成画面同比例：
 *  - 宿主侧的"视频面尺寸 = 画面比例"做法能覆盖留黑边的「适应」，
 *    但「填充（等比放大 + 裁剪）」「拉伸」必须让画面溢出/铺满同一个视频面；
 *  - 软解路径的画面来自本渲染器上传的纹理，只有它自己知道帧的真实像素尺寸，
 *    由它按模式换算顶点缩放最直接，也不需要宿主重复计算。
 *
 * 数值与 ArkTS 侧 `PlayerAspectMode`（contain/cover/stretch/original => 0/1/2/3）一一对应，
 * 跨 NAPI 传递时直接传这个整数，避免字符串在两处各写一遍。
 */
enum class ScaleMode : int {
    /** 适应：等比缩放，整幅画面可见，多余区域留黑边（默认，主流播放器的默认行为） */
    Contain = 0,
    /** 填充：等比放大铺满，超出部分被裁剪（不变形） */
    Cover = 1,
    /** 拉伸：非等比铺满（会变形，但消除黑边） */
    Stretch = 2,
    /** 原始：1 个视频像素对应 1 个屏幕像素；超出屏幕时退回「适应」 */
    Original = 3,
};

/**
 * 把 RGBA 帧渲染到 XComponent 的 surface（EGL + GLES）。
 *
 * 为什么需要：软解在 CPU 上出帧后必须上屏；用 `Image(PixelMap)` 逐帧刷新既重又易踩生命周期坑，
 * 直接渲染进视频面（surface）才是播放器该有的路径，也是流畅播放的前提。
 *
 * 线程约束：EGL 上下文与 GL 调用必须在**同一线程**内完成（本项目为 ArkTS 的 UI 线程，
 * 帧循环里的 `softPlayRenderLast()` 就在该线程上）。这不是"建议"而是硬约束：
 * EGL/DGLES 把"当前上下文 / 当前 surface"记在**线程私有**状态里，初始化在某线程、
 * 渲染在另一线程时 `eglSwapBuffers` 只会失败（实测 `EGL_BAD_SURFACE`，驱动侧
 * `g_handle is null`），画面全黑而**上层拿不到任何异常** —— 这正是"软解黑屏"的成因。
 * 因此 `init*()` 必须由**将来调用 `renderRgba()` 的那个线程**发起；
 * `drawFrame()` 会主动校验，线程不符时如实报错而不是静默黑屏。
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

    /** 上传一帧 RGBA 并绘制、交换缓冲（按 `scaleMode()` 决定留黑边/裁剪/铺满） */
    bool renderRgba(const uint8_t *rgba, int width, int height, std::string &error);

    /**
     * 设置画面缩放模式（播放中可随时切换，下一帧生效）。
     * 见 `ScaleMode`：这是「视频比例」在软解路径上的落点。
     */
    void setScaleMode(ScaleMode mode) { scaleMode_ = mode; }

    ScaleMode scaleMode() const { return scaleMode_; }

    /**
     * 从**当前渲染缓冲**回读像素（glReadPixels）。
     * 用于验证"确实渲染出来了"——不依赖系统截图是否含 surface 内容。
     */
    bool readbackRgba(std::vector<uint8_t> &out, int &width, int &height, std::string &error);

    /**
     * 渲染自检：只做 `glClearColor(红)` + `glReadPixels` 回读中心像素 + `eglSwapBuffers`，
     * 用于把"surface 不能作为 GL 目标"与"绘制路径有 bug"两类问题一刀切开。
     * @param report 人类可读结果（几何、清屏后中心像素、swap 结果）
     * @return 清屏颜色是否正确回读（true 表示 surface 可渲染）
     */
    bool selfTest(std::string &report);

    /**
     * 另一条渲染目标路径：XComponent 为 `TEXTURE` 类型时，surfaceId 实际是 GL 纹理 id，
     * 需经 `OH_NativeImage` 取得可渲染的 native window，渲染后调用 `UpdateSurfaceImage` 发布。
     * 用于绕开「SURFACE 类型 surface 无法作为 GL 目标」的平台限制（实测见于 DevEco x86_64 模拟器）。
     */
    bool initFromTexture(uint32_t textureId, std::string &error, int requestedWidth = 0,
                         int requestedHeight = 0);

    /**
     * **官方路径**：用 ArkUI 经 `OH_NativeXComponent` 回调交来的 `OHNativeWindow*` 初始化
     * （见 `xcomponent_bridge.h`）。相比 surfaceId 方式，window 与尺寸都由 framework 给出。
     *
     * @param surfaceGeneration 该 surface 的世代号（`XComponentBridge::SurfaceGeneration()`），
     *                          仅用于诊断与"是否仍是同一块 surface"的判定，可传 0。
     */
    bool initFromWindow(void *nativeWindow, int width, int height, std::string &error,
                        uint64_t surfaceGeneration = 0);

    /**
     * 重绘最近一帧并在 **swap 之前** 回读帧缓冲（导出渲染结果的正确做法）。
     *
     * 为什么不能直接读：`eglSwapBuffers` 之后后台缓冲内容未定义，`glReadPixels` 会读到全黑
     * （实测：swap 后导出 1260x2619 全黑；而 swap 前的清屏自检能正确读到 `rgba=(255,0,0,255)`）。
     */
    bool redrawAndReadback(const uint8_t *rgba, int width, int height, std::vector<uint8_t> &out,
                           int &outWidth, int &outHeight, std::string &error);

    void destroy();
    bool isReady() const { return ready_; }

    /**
     * 渲染器当前是否绑在这块 native window 上。
     *
     * 为什么需要：渲染器是进程级单例，而 XComponent 的 surface 会随页面进出/旋转被销毁重建。
     * 只按 `isReady()` 复用，就会把帧画到**已经死掉的 surface** 上 —— 画面不变、也不报错
     * （实测表现同样是"软解黑屏"）。宿主必须先比对 window 指针，不同则重新 `init*()`。
     */
    bool boundToWindow(const void *window) const { return ready_ && nativeWindow_ == window; }

    /** 初始化时那块 surface 的世代号（`XComponentBridge::SurfaceGeneration()`） */
    uint64_t surfaceGeneration() const { return surfaceGeneration_; }

    /** 初始化（= GL 调用必须与之同线程）所在的线程 id（0 表示未知/未初始化） */
    uint64_t renderThreadId() const { return renderThreadId_; }

    /** 是否走 TEXTURE 路径（OH_NativeImage：帧直接上传到 XComponent 纹理并发布，不做 swap） */
    bool isTexturePath() const { return nativeImage_ != nullptr; }

    /**
     * 当前渲染缓冲（= 实际上屏）的像素几何。
     *
     * 宿主应把解码尺寸对齐到这里：解码到更大只是白白多付一次 `swscale` 的开销
     * （最终仍被缩进缓冲），解码到更小则画面直接变糊。
     */
    int renderWidth() const { return surfaceWidth_; }
    int renderHeight() const { return surfaceHeight_; }

    /** 缓冲因 `eglSwapBuffers` 失败而降级的次数（>0 表示本设备吃不下初始几何） */
    int degradeCount() const { return degradeCount_; }

    /**
     * 查询给定 surface 上**实际可用的**渲染缓冲几何。
     *
     * 为什么必须查询而不是写死常量：能吃下多大的缓冲完全取决于设备的 GL 实现
     * （模拟器是软件光栅化、真机是硬件），任何固定值都必然在其中一端出错 ——
     * 写大 → 模拟器 `eglSwapBuffers` 直接失败（0x12301），写小 → 真机画面被无谓地降质。
     *
     * TEXTURE（OH_NativeImage）路径的缓冲几何由 XComponent 尺寸决定，平台不接受任意值，
     * 因此返回期望几何并不作主观限制；window surface 路径的几何由 `SET_BUFFER_GEOMETRY`
     * 显式指定，返回期望几何，真正的上限只能在 swap 失败后由降级阶梯发现。
     */
    static void queryRenderGeometry(bool texturePath, int requestedWidth, int requestedHeight,
                                    int &width, int &height);

private:
    /** 两条路径共用的初始化：EGL display/config/context、着色器程序、纹理与顶点缓冲 */
    bool initWithWindow(void *window, int requestedWidth, int requestedHeight, std::string &error);

    /** 把缓冲几何下发给 native window（仅 window surface 路径有效），并同步 surfaceWidth_/Height_ */
    void applyBufferGeometry(int width, int height);

    /** 上传纹理并绘制一帧（不含 swap 与发布），供 renderRgba 与导出前重绘共用 */
    bool drawFrame(const uint8_t *rgba, int width, int height, std::string &error);

    bool buildProgram(std::string &error);

    uint64_t surfaceId_ = 0;
    void *nativeWindow_ = nullptr;
    void *display_ = nullptr;   // EGLDisplay
    void *context_ = nullptr;   // EGLContext
    void *surface_ = nullptr;   // EGLSurface
    unsigned int xcomponentTextureId_ = 0;   // TEXTURE 路径：XComponent 提供的纹理 id
    unsigned int program_ = 0;
    unsigned int texture_ = 0;
    unsigned int vbo_ = 0;
    int attribPos_ = -1;
    int attribUv_ = -1;
    int uniformTex_ = -1;
    /** 顶点缩放 uniform（画面比例：留黑边/裁剪/铺满都靠它换算，避免每帧重建顶点缓冲） */
    int uniformScale_ = -1;
    ScaleMode scaleMode_ = ScaleMode::Contain;
    int surfaceWidth_ = 0;
    int surfaceHeight_ = 0;
    int requestedWidth_ = 0;
    int requestedHeight_ = 0;
    /** 初始化时从 native window 读到的缓冲几何（诊断用） */
    std::string geometryAtInit_;
    bool ready_ = false;
    /** 非空表示走 OH_NativeImage（TEXTURE）路径，渲染后需 UpdateSurfaceImage */
    void *nativeImage_ = nullptr;
    /** 缓冲几何因 swap 失败而降级的次数（用于把"本设备吃不下该几何"如实报给宿主） */
    int degradeCount_ = 0;
    /**
     * `nativeWindow_` 是否由**我们**创建（= `init(surfaceId)` 路径）。
     *
     * 只有自己创建的 window 才能销毁。framework 经 `OH_NativeXComponent` 回调交来的 window
     * 属于 ArkUI，`initFromTexture` 的 window 属于 `OH_NativeImage`（销毁 NativeImage 即可）
     * —— 误销毁它们会毁掉 XComponent 的显示面（实测：之后在同一 XComponent 上重建 EGL surface，
     * `eglSwapBuffers` 报 `0x12301`，画面再也不上屏）。
     */
    bool windowOwned_ = false;
    /** 初始化时的 surface 世代号（诊断 / 换 surface 判定用） */
    uint64_t surfaceGeneration_ = 0;
    /** 初始化所在线程 id：GL 调用必须与之相同（见类注释的线程约束） */
    uint64_t renderThreadId_ = 0;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_EGL_RENDERER_H */
