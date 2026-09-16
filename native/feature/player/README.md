# feature/player —— 可移植的播放能力（FFmpeg 软解 + EGL 渲染）

本目录是**自包含**的播放实现，目的是能整目录拷到其它 HarmonyOS 工程里复用。

## 提供什么

| 文件 | 职责 |
|---|---|
| `soft_decode_session.{h,cpp}` | **流式软解会话**：HTTP Range 分页取流（自定义 AVIO）→ libavformat 解容器 → 软件解码 → `swscale` 转 RGBA 逐帧输出；支持 seek |
| `range_cache.{h,cpp}` | **Range 分页缓存**：把顺序读翻译成按需 Range 请求并缓存最近一块；不依赖 FFmpeg 与任何 HTTP 实现，**可在主机上单测**（`native/core/tests/test_range_cache.cpp`，29 项断言） |
| `ffmpeg_decoder.{h,cpp}` | 一次性**内存探测**：解析容器/编码/宽高/像素格式，可导出首帧 PNG（用于能力检测与诊断） |
| `egl_renderer.{h,cpp}` | **EGL/GLES 渲染**：surfaceId → native window → EGL surface/context → 纹理上传 RGBA 并绘制；含 `readbackRgba()`（glReadPixels 回读，用于验证渲染结果） |
| `range_fetcher.{h,cpp}` | **取流抽象**：宿主注入 `RangeFetchFn`，本目录不依赖任何具体 HTTP 实现 |
| `playback_policy.{h,cpp}` | Jellyfin `PlaybackInfo` → 播放方式（DirectPlay/DirectStream/Transcode）解析（偏业务，移植时可不用） |
| `hw_decoder.*` `subtitle.*` `engine.*` `version.*` | 硬解/字幕/引擎/版本占位与接口 |

## 依赖

1. **FFmpeg 7.1 共享库**（LGPL-2.1+，动态链接）：
   `libavformat` `libavcodec` `libavutil` `libswscale` `libswresample`
   本仓库的交叉编译脚本：`scripts/build_ffmpeg_ohos.sh`（x86_64 / arm64-v8a）
   公开头文件：`native/third_party/ffmpeg/include`；许可与分发要求见 `native/third_party/NOTICE`
2. **OHOS NDK 图形库**：`EGL` `GLESv3` `native_window`
3. C++17

## 接入步骤（移植到其它工程）

1. 拷贝 `feature/player/` 整个目录。
2. 构建：
   - 把该目录加入源码（本仓库用 CMake glob，见 `native/app/entry/src/main/cpp/CMakeLists.txt`）
   - 链接 5 个 FFmpeg 库 + `EGL` + `GLESv3` + `native_window`
   - 编译宏：找到 FFmpeg 时定义 **`JELLYFIN_HAS_FFMPEG`**；未定义时软解相关接口会明确返回"不可用"，不会假装能解码
   - 头文件搜索路径包含 `feature/player` 与 FFmpeg include 目录
3. **注入取流器**（唯一必须由宿主提供的东西）：

```cpp
jellyfin::player::SetRangeFetcher([](const std::string &url, int64_t start, int64_t end) {
    jellyfin::player::RangeResponse out;
    // 用你自己的网络栈发起请求；支持 Range 更好（可边下边解），不支持也能顺序读
    // end >= start → Range: bytes=start-end；end < 0 → 请求整段
    out.status = ...; out.body = ...; out.error = ...;
    return out;
});
```
本仓库的注入示例见 `native/napi/jellyfin_napi.cpp` 的 `EnsureRangeFetcher()`（基于 core 的 HttpClient，自带 mbedTLS/https 与 Jellyfin 鉴权）。

4. 软解播放：

```cpp
jellyfin::player::SoftDecodeSession session;
std::string error;
if (!session.openUrl(playUrl, error)) { /* 处理错误 */ }

jellyfin::player::EglRenderer renderer;
if (renderer.init(surfaceId, error, surfaceWidthPx, surfaceHeightPx)) { /* EGL 就绪 */ }

std::vector<uint8_t> rgba;
jellyfin::player::SoftDecodeSession::FrameInfo frame;
while (session.nextFrameRgba(0, rgba, frame)) {     // maxWidth=0 → 原分辨率
    renderer.renderRgba(rgba.data(), frame.width, frame.height, error);
}
```
`surfaceId` 在 ArkTS 侧由 `XComponentController.getXComponentSurfaceId()` 取得。

## 注意事项（踩过的坑）

- **线程**：`SoftDecodeSession` 与 `EglRenderer` 都不是线程安全的，且 EGL 调用必须与创建上下文的线程一致；
  当前实现由 ArkTS 定时器驱动，在 UI 线程顺序拉帧（约 14fps）。要提帧率需把解码搬到工作线程 + 双缓冲队列。
- **缓冲几何**：创建 EGL surface **之前**就要设置正确几何。实测 OHOS 上 `GET_BUFFER_GEOMETRY` 可能返回
  **宽高转置**的值（2619x1260 vs 实际 1260x2619），会导致 `eglSwapBuffers` 失败；因此建议由宿主传入组件真实像素尺寸。
- **XComponent 的 surface**：软解渲染与系统 AVPlayer 不能同时占用同一个 surface，切换前要先停掉另一方。
- **SURFACE 与 TEXTURE 两种 XComponent 类型差别很大（实测，务必先判定）**：
  | XComponent 类型 | 实测结果（DevEco x86_64 模拟器） |
  |---|---|
  | `SURFACE` + `OH_NativeWindow_CreateNativeWindowFromSurfaceId` | ❌ 不可用：`eglSwapBuffers` 每帧报 `0x12301`（非标准 EGL 错误码），`selfTest()` 清屏回读为 `rgba=(0,0,0,0)` —— 连 `glClear` 都没落到缓冲 |
  | `TEXTURE` + `OH_NativeImage`（本模块推荐路径） | ✅ 可用：`selfTest()` 回读 `rgba=(255,0,0,255)`，`glReadPixels=OK`、`eglSwapBuffers=OK` |
  **结论**：若要把软解帧渲染上屏，优先用 `XComponentType.TEXTURE` + `initFromTexture()`；
  换机型/换类型前先跑 `selfTest()`（或宿主的 `renderTargetProbe`）判定，能省下大量盲调时间。
- **TEXTURE 路径的调用顺序**：`eglSwapBuffers()` **之后**才调用 `OH_NativeImage_UpdateSurfaceImage()`；
  顺序颠倒会返回 `NATIVE_ERROR_NO_BUFFER (40601000)`（"还没有 buffer 可发布"）。
- **导出"渲染结果"必须先重绘再回读**：`eglSwapBuffers()` 之后后台缓冲内容未定义，
  直接 `glReadPixels` 会得到**全黑**（实测踩过，一度误判为渲染失败）；
  正确做法是重绘最近一帧 → `glFinish` → 在 swap **之前**回读（见 `redrawAndReadback()`）。
- **EOF 的判定（`RangeCache`）**：HTTP `416` 与"2xx 且响应体为空"都应视为**读到末尾**而非错误，
  否则 libavformat 会在末尾收到 `EIO`；而"status=0 / 带 error"必须报错，不能静默当 EOF。
  另注意：服务器支持 Range 且每次返回整块时**无法**推断总长度（响应经回调返回、不含响应头），
  此时 `size()` 为 -1 属正常，长度会在读到末尾时补上。
- **音频**：本目录尚未包含音频输出（需宿主接 `OH_AudioRenderer`）。
- **许可**：FFmpeg 为 LGPL-2.1+，必须动态链接并随包提供许可与源码获取方式（见 `native/third_party/NOTICE`）。
