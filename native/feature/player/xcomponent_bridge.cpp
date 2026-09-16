#include "xcomponent_bridge.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <node_api.h>

#include <atomic>
#include <mutex>

namespace jellyfin {
namespace player {
namespace {

constexpr unsigned int kLogDomain = 0x0000;
constexpr const char *kLogTag = "XComponentBridge";

std::mutex g_mutex;
OH_NativeXComponent *g_component = nullptr;
void *g_window = nullptr;
int g_width = 0;
int g_height = 0;
std::atomic<bool> g_surfaceReady{false};
std::atomic<uint64_t> g_generation{0};

/** surface 创建/变更：framework 在这里把 OHNativeWindow* 交给我们（官方 EGL/GLES 入口） */
void OnSurfaceCreated(OH_NativeXComponent *component, void *window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    const int32_t rc = OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_window = window;
        g_width = rc == 0 ? static_cast<int>(width) : 0;
        g_height = rc == 0 ? static_cast<int>(height) : 0;
    }
    g_surfaceReady.store(true);
    g_generation.fetch_add(1);
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "OnSurfaceCreated window=%{public}p size=%{public}dx%{public}d rc=%{public}d",
                 window, g_width, g_height, rc);
}

void OnSurfaceChanged(OH_NativeXComponent *component, void *window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_window = window;
        g_width = static_cast<int>(width);
        g_height = static_cast<int>(height);
    }
    g_surfaceReady.store(true);
    g_generation.fetch_add(1);
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "OnSurfaceChanged size=%{public}dx%{public}d", g_width, g_height);
}

void OnSurfaceDestroyed(OH_NativeXComponent * /*component*/, void * /*window*/)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = nullptr;
    g_surfaceReady.store(false);
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "OnSurfaceDestroyed");
}

OH_NativeXComponent_Callback g_callback = {
    OnSurfaceCreated,
    OnSurfaceChanged,
    OnSurfaceDestroyed,
    nullptr,   // DispatchTouchEvent：手势仍由 ArkUI 处理
};

} // namespace

void XComponentBridge::Register(napi_env env, napi_value exports)
{
    napi_value exportInstance = nullptr;
    // ArkUI 在 XComponent 指定 libraryname: '<本模块>' 时，会把 OH_NativeXComponent 注入到 exports
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok ||
        exportInstance == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "exports 中无 %{public}s（XComponent 未使用 libraryname 指向本模块）",
                     OH_NATIVE_XCOMPONENT_OBJ);
        return;
    }
    OH_NativeXComponent *component = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void **>(&component)) != napi_ok ||
        component == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, "napi_unwrap OH_NativeXComponent 失败");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_component = component;
    }
    const int32_t rc = OH_NativeXComponent_RegisterCallback(component, &g_callback);
    OH_LOG_Print(LOG_APP, rc == 0 ? LOG_INFO : LOG_ERROR, kLogDomain, kLogTag,
                 "OH_NativeXComponent_RegisterCallback rc=%{public}d", rc);
}

bool XComponentBridge::IsRegistered()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_component != nullptr;
}

bool XComponentBridge::IsSurfaceReady()
{
    return g_surfaceReady.load();
}

void *XComponentBridge::SurfaceWindow()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_window;
}

bool XComponentBridge::SurfaceSize(int &width, int &height)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    width = g_width;
    height = g_height;
    return g_window != nullptr && g_width > 0 && g_height > 0;
}

uint64_t XComponentBridge::SurfaceGeneration()
{
    return g_generation.load();
}

} // namespace player
} // namespace jellyfin
