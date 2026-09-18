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

/** 最新触摸事件（由 OnDispatchTouchEvent 写入，由 TakeTouchEvent 读取并清除） */
std::mutex g_touchMutex;
TouchEventData g_latestTouch;

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
    // window 指针一并记录：渲染器按"是否仍是同一块 window"决定复用还是重建，
    // 排查"旋转/切比例后画面异常"时需要它来区分"只是换尺寸"与"换了一块显示面"。
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "OnSurfaceChanged window=%{public}p size=%{public}dx%{public}d", window, g_width,
                 g_height);
}

void OnSurfaceDestroyed(OH_NativeXComponent * /*component*/, void * /*window*/)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = nullptr;
    g_surfaceReady.store(false);
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "OnSurfaceDestroyed");
}

/**
 * 视频区域触摸回调（官方契约：`OH_NativeXComponent_Callback.DispatchTouchEvent`）。
 *
 * **本回调必须非 nullptr。** 这是设备实测的关键结论：此前该字段是 `nullptr`，
 * 结果框架**根本不向视频区域派发触摸**，视频区的 seek/音量/亮度/长按手势全部失效；
 * 换成真实函数后，位于 XComponent 之上的 ArkUI 透明手势层立刻能收到触摸。
 * 也就是说，这个回调在此配置下的作用是"声明原生组件参与输入派发"，
 * 而不是"由原生侧判定手势"。
 *
 * 实测补充（hilog `XComponentBridge`）：`OH_NativeXComponent_RegisterCallback rc=0`、
 * `OnSurfaceCreated` 均正常，但本回调**从未被调用** —— ArkUI 在应用层就消化了触摸
 * （`player_gesture.txt` 里记录的是 ArkUI 手势层的 `gesture seekDeltaMs=...`）。
 * 因此这里捕获的触摸事件是一条**兜底通道**：宿主按需低频轮询，
 * 一旦原生侧真的开始派发，宿主立刻切回高频以保证跟手（见 PlayerPage 的自适应退避）。
 *
 * 官方文档：`OH_NativeXComponent_GetTouchEvent` 获取触摸点与动作；
 * `OH_NativeXComponent_TouchEventType`：DOWN=0 / UP=1 / MOVE=2 / CANCEL=3 / UNKNOWN=4。
 */
void OnDispatchTouchEvent(OH_NativeXComponent *component, void *window)
{
    OH_NativeXComponent_TouchEvent touchEvent;
    const int32_t rc = OH_NativeXComponent_GetTouchEvent(component, window, &touchEvent);
    if (rc != 0) {
        return;
    }
    // 将触摸事件存储到共享状态，供 ArkTS 轮询读取。
    // 这里**不做任何日志**：触摸是最热的路径，逐事件打点会污染 hilog 并拖慢输入响应。
    {
        std::lock_guard<std::mutex> lock(g_touchMutex);
        g_latestTouch.type = static_cast<int>(touchEvent.type);
        g_latestTouch.x = touchEvent.x;
        g_latestTouch.y = touchEvent.y;
        g_latestTouch.numPoints = static_cast<int>(touchEvent.numPoints);
        g_latestTouch.timestamp = static_cast<int64_t>(touchEvent.timeStamp);
        g_latestTouch.valid = true;
    }
}

OH_NativeXComponent_Callback g_callback = {
    OnSurfaceCreated,
    OnSurfaceChanged,
    OnSurfaceDestroyed,
    OnDispatchTouchEvent,   // 视频区触摸 → 原生侧（官方契约）
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

bool XComponentBridge::TakeTouchEvent(TouchEventData &out)
{
    std::lock_guard<std::mutex> lock(g_touchMutex);
    if (!g_latestTouch.valid) {
        return false;
    }
    out = g_latestTouch;
    g_latestTouch.valid = false;
    return true;
}

} // namespace player
} // namespace jellyfin
