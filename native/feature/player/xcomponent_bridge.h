#ifndef JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H
#define JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H

#include <cstdint>

struct napi_env__;
typedef struct napi_env__ *napi_env;
struct napi_value__;
typedef struct napi_value__ *napi_value;

namespace jellyfin {
namespace player {

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
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_FEATURE_PLAYER_XCOMPONENT_BRIDGE_H */
