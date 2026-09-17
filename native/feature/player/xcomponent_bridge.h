#ifndef JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H
#define JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H

#include <cstdint>
#include <string>

struct napi_env__;
typedef struct napi_env__ *napi_env;
struct napi_value__;
typedef struct napi_value__ *napi_value;

namespace jellyfin {
namespace player {

/**
 * 触摸事件数据（由 OnDispatchTouchEvent 捕获，供 ArkTS 轮询读取）。
 *
 * 为什么需要：XComponent 指定 libraryname 后，视频区域的触摸由原生侧接管，
 * ArkUI 层的 onTouch/onClick 收不到。通过将触摸事件存储在共享状态中，
 * ArkTS 可以轮询获取并处理手势（seek/音量/亮度/长按快进）。
 */
struct TouchEventData {
    /** 事件类型：0=down 1=up 2=move 3=cancel */
    int type = -1;
    /** 触摸点坐标（相对于 XComponent 组件） */
    float x = 0.0f;
    float y = 0.0f;
    /** 触摸点数量 */
    int numPoints = 0;
    /** 时间戳（毫秒） */
    int64_t timestamp = 0;
    /** 是否有效（true 表示有新数据可读） */
    bool valid = false;
};

/**
 * 官方 XComponent 原生渲染桥（`ace/xcomponent/native_interface_xcomponent.h`）。
 *
 * 为什么用它：SDK 头文件对 `OH_NativeXComponent` 的说明就是 "Describes the surface and touch
 * event held by the ArkUI XComponent, which can be used for the **EGL/OpenGL ES** and media data
 * input and displayed on the ArkUI XComponent" —— 即 ArkUI 官方的原生渲染入口。
 *
 * 与 `OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId)` 的区别：那条路由 ArkTS 传
 * surfaceId、原生侧自行创建 window；本桥由 ArkUI 在 surface 就绪时**直接回调**交给我们 framework
 * 持有的 `OHNativeWindow*`（`OnSurfaceCreated(component, window)`），并可通过
 * `OH_NativeXComponent_GetXComponentSize()` 取到组件尺寸，无需猜测几何。
 */
class XComponentBridge {
public:
    /** 在 NAPI 模块 init 中调用：拿下 ArkUI 注入的 OH_NativeXComponent 并注册回调 */
    static void Register(napi_env env, napi_value exports);

    /** 是否已注册成功（即 XComponent 使用了 libraryname 指向本模块） */
    static bool IsRegistered();

    /** surface 是否已创建（OnSurfaceCreated 已回调） */
    static bool IsSurfaceReady();

    /** framework 提供的 native window（未就绪返回 nullptr） */
    static void *SurfaceWindow();

    /** 组件尺寸（像素）；未就绪返回 false */
    static bool SurfaceSize(int &width, int &height);

    /** 供渲染器在 surface 重建后重新初始化（每次 OnSurfaceCreated/Changed 都会自增） */
    static uint64_t SurfaceGeneration();

    /**
     * 读取并清除最新的触摸事件（线程安全）。
     * @param out 输出触摸事件数据
     * @return true 表示有新事件，false 表示无新事件
     */
    static bool TakeTouchEvent(TouchEventData &out);
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H */
