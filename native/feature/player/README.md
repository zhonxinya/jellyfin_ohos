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
   预编译产物**随仓库提交**：`native/app/entry/libs/{x86_64,arm64-v8a}/`（克隆后直接可用）
   需要刷新时的交叉编译脚本：`scripts/build_ffmpeg_ohos.sh`（x86_64 / arm64-v8a）
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

> ⚠️ 上面这段是最小可运行示例（**单线程**：open/decode/render 在同一线程，天然满足 EGL 的
> 同线程约束）。一旦把 `openUrl()`（网络/解析）挪到工作线程以避免阻塞 UI，**必须同时把
> `renderer.init*()` 留在渲染线程**，否则会得到"帧在解、屏幕全黑、无任何报错"的结果
> （见下方"EGL 的'同线程'约束"）。本工程的做法：`softPlayOpen` 异步打开会话，
> 渲染器由一个**同步**接口在 UI 线程初始化，`softPlayRenderLast` 同样在 UI 线程逐帧渲染。

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
- **自检必须与真实绘制走同一条路径**：`selfTest()` 现在分两步 ——
  ①清屏为红并回读（判定 surface 能否作为渲染目标）；②**用程序生成的 2×2 纹理绘制四边形并回读**
  （判定着色器/VBO/attribute/纹理采样这一整条绘制路径是否真的产出内容）。
  实测第二步回读为 `rgba=(128,128,128,255)`（四个纹素经线性过滤的平均值）⇒ **绘制路径正常**。
  这个两步自检能把"surface/发布层"与"绘制层"的问题一刀切开，强烈建议移植后先跑它。
- **自检的收尾必须无条件把画面恢复为中性色（两条路径都要）** —— 踩过的坑：
  收尾的"清黑 + swap"原本被 `if (nativeImage_ != nullptr)` 包着，只覆盖 TEXTURE 路径；
  而宿主 `softPlayOpen` 的 `'xcomponent'` 模式走的是 `initFromWindow()`（window surface，
  `nativeImage_` 恒为 `nullptr`），于是**"清屏为红"的测试图案再也没被抹掉**。
  设备实测后果：起播即结束（续播点靠近片尾）时视频区整块红屏（截图统计 `avg=(224,6,6)`），
  看起来像渲染坏了。**自检是有副作用的**：它会改写可见 surface，宿主必须假设"自检之后
  屏幕上留下的是测试图案"，并立刻用真实帧或中性色覆盖。
- **TEXTURE 路径的三种渲染目标配置（均实测，便于移植时少走弯路）**：

  | 配置 | 实测结果（DevEco x86_64 模拟器） |
  |---|---|
  | window surface（`AcquireNativeWindow` + `eglCreateWindowSurface`）+ 绘制 + `eglSwapBuffers` + `UpdateSurfaceImage` | ✅ swap 与发布均成功（状态 `EGL 已渲染`），**但发布出去的内容为黑**（系统截图/组件快照/回读三者一致为黑） |
  | pbuffer + `glTexImage2D` 直接写 XComponent 纹理 + `UpdateSurfaceImage` | ❌ 发布失败 `NATIVE_ERROR_NO_BUFFER(40601000)`（`glTexImage2D` 会重新分配纹理，疑破坏 NativeImage 与纹理的绑定） |
  | pbuffer + **FBO（以 XComponent 纹理为颜色附件）** + 绘制 + `UpdateSurfaceImage` | ❌ 同样 `40601000`；且自检读数会失真（pbuffer 尺寸 ≠ surface 尺寸） |

  本模块当前保留**第一种**（唯一能成功发布的配置）。同环境下 SURFACE 类型则连 swap 都失败（`0x12301`）。
  **结论：TEXTURE（`OH_NativeImage`）这条路径在该模拟器上发布不出内容**；解码与绘制本身已通过自检
  证明正常（见上一条）。移植到真机时建议先跑 `selfTest()` 与 `renderTargetProbe`，再决定采用哪种配置。

  > **补记（后续排查结论，见"EGL 必须与渲染同线程"那条）**：本工程实际用的是
  > **SURFACE + `OH_NativeXComponent` 回调的 window**（`initFromWindow()`），它在该模拟器上
  > 是**可以**把软解帧显示出来的 —— 早先"软解黑屏"的真正原因是 EGL 在**工作线程**初始化、
  > 渲染却在 UI 线程（`EGL_BAD_SURFACE`），而不是"模拟器显示不出软解帧"。
  > 该表述此前容易误导移植者，故在此更正。
- **EOF 的判定（`RangeCache`）**：HTTP `416` 与"2xx 且响应体为空"都应视为**读到末尾**而非错误，
  否则 libavformat 会在末尾收到 `EIO`；而"status=0 / 带 error"必须报错，不能静默当 EOF。
  另注意：服务器支持 Range 且每次返回整块时**无法**推断总长度（响应经回调返回、不含响应头），
  此时 `size()` 为 -1 属正常，长度会在读到末尾时补上。
- **音频**：本目录尚未包含音频输出（需宿主接 `OH_AudioRenderer`）。
- **播放中切换音频/字幕轨（宿主侧做法，实测可用）**：不要用"重新请求播放地址再 seek"这种重开式切换，
  优先用 **AVPlayer 自身的轨道接口**，画面不中断、进度不跳：
  1. `prepared` 之后 `getTrackDescription()` 拿到文件真实轨道
     （`track_index` / `track_type`：0=音频 1=视频 2=字幕 / `language` / `channel_count`）；
  2. 音频、**内嵌**字幕直接 `selectTrack(trackIndex)`；关闭字幕用 `deselectTrack`；
  3. **外挂**字幕先 `addSubtitleFromUrl(url)`（Jellyfin 侧由宿主构造
     `/Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/Stream.vtt`，服务端会按格式转换），
     再在轨道列表里找出新增的字幕轨并 `selectTrack`；
  4. 字幕文本由播放器通过 `on('subtitleUpdate')` 推给应用（`{ startTime, duration, text }`），
     **应用自己绘制**（原生 SURFACE 上画不了文本）；该浮层要设 `hitTestBehavior(HitTestMode.None)`，否则挡手势。
  踩过的坑：
  - `getSelectedTracks()` 在 `selectTrack()` 之后**立刻**读可能仍是旧值（异步生效），
    要过一会儿（本次实测重开面板时）才读到新值 —— 别据此判定"切换失败"；
  - 同一文件里"第 N 条 Jellyfin 音频/字幕流"与"第 N 条 AVPlayer 轨道"顺序一致，
    实测用默认轨（文件默认音轨 = Jellyfin 的 Default 流）交叉验证过，可按序号映射；
  - ArkTS 侧 `ForEach` 的 key 必须包含"是否选中"，否则切换后选中标记不会移动（key 未变 → 该项不重建）；
  - 转码/无轨道信息的场景才回退到"改写 `AudioStreamIndex`/`SubtitleStreamIndex` → 重新取流 → seek 回原位"。
- **软解取流绝不能放在 UI 线程上（本模块踩过的最严重的一个坑）**：
  `RangeCache::read()` 未命中缓存时会走 `FetchRange()`（宿主的同步 HTTP）。设备实测 faultlog
  主线程栈为 `RangeCache::read → fillCache → FetchRange → IsHttpResponseComplete` +
  `THREAD_BLOCK_6S`：逐帧拉取时一次网络往返就把主线程阻塞 6 秒以上，系统判 appfreeze、
  界面直接消失（看起来像"应用退出"，累计 8 条）。两层防护，缺一不可：
  1. `RangeCache::startPrefetch()` 后台线程预取（默认领先 8 块 = 8 MiB），把取流移出读取路径；
  2. 宿主侧**帧拉取必须异步**（本项目 `softPlayNextFrame` 用 `napi_create_async_work`），
     UI 线程只等 Promise —— 预取只覆盖"顺序向前读"，容器解析到处 seek 与网络跟不上时仍会 miss。
- **EGL 的"同线程"约束是硬约束：初始化必须由"将来渲染的那个线程"发起**（本项目是 UI 线程）。
  踩过的坑（"软解黑屏"的根因）：`softPlayOpen` 是 `RunAsync`（工作线程），早期实现顺手在那里
  `eglInitialize` + 建 surface；而逐帧渲染走的是**同步**接口 `softPlayRenderLast()`（UI 线程）。
  EGL/DGLES 把"当前上下文 / 当前 surface"记在**线程私有**状态里，于是 UI 线程的每一次
  `eglSwapBuffers` 都失败 —— 设备实测驱动日志每 70ms 一条
  `DGLES: EGL_BAD_SURFACE, g_handle is null`（0x300d，单次播放累计 17126 条），
  而**帧号照涨、进度照走、上层拿不到任何错误**，用户看到的是一块纯黑。
  正确拆法：
  1. 会话/取流可以放工作线程（`softPlayOpen`/`softPlayNextFrame`）；
  2. **EGL 初始化必须由渲染线程发起** —— 本项目加了一个同步接口 `softPlayInitRenderer()`
     （宿主在 UI 线程调用，只做一次，实测约 35ms）；
  3. `drawFrame()` 内部再兜一层：校验调用线程 == 初始化线程，并**检查 `eglMakeCurrent`
     的返回值**（忽略它就等于把"上下文没绑上"当成"绘制成功"）。
  另外注意：渲染器是进程级单例，而 XComponent 的 surface 会随页面进出被销毁重建 ——
  只按 `isReady()` 复用会把帧画到**已经死掉的显示面**上（同样不报错、画面不动）。
  复用的判据是 `boundToWindow(当前 window)`，不一致就重新 `init*()`。
- **不要销毁 framework 持有的 native window**：`initFromWindow()` 的 window 来自
  `OH_NativeXComponent` 回调（属于 ArkUI），`initFromTexture()` 的 window 属于 `OH_NativeImage`
  （销毁 NativeImage 即可）。只有自己用 `OH_NativeWindow_CreateNativeWindowFromSurfaceId`
  创建的 window 才能 `OH_NativeWindow_DestroyNativeWindow()`。误销毁的实测后果：显示面被毁，
  之后在同一 XComponent 上重建 EGL surface 时 `eglSwapBuffers` 报 `0x12301`，画面再也不上屏。
- **EGL 渲染必须留在初始化/上次渲染所在线程（本项目是 UI 线程）**：把 `renderRgba()` 放到
  线程池线程后，`eglSwapBuffers` 返回 **`0x12301`**、帧解出来了但**上不了屏**
  （诊断行显示"未渲染"）。正确拆法是"工作线程只解码 + UI 线程渲染"：
  `softPlayNextFrame()`（异步，解码并缓存最近帧）+ `softPlayRenderLast()`（同步，UI 线程调用）。
- **软解会话的 seek**：`SoftDecodeSession::seek(seconds)` 跳转到指定时间点（秒），
  实现为 `av_seek_frame(AVSEEK_FLAG_BACKWARD)` + `avcodec_flush_buffers()`。
  两点容易漏：①`av_seek_frame(fmt, -1, ts, ...)` 的 `stream_index = -1` 要求时间戳是
  `AV_TIME_BASE`（微秒）单位，不是秒；②seek 后必须 `avcodec_flush_buffers()`，
  否则解码器里残留的旧帧会先被吐出来（表现为"seek 了但先闪几帧旧画面"）。
- **播放中的 seek 必须"排队"，不要在宿主（UI）线程直接调 `seek()`**：`seek()` 里的
  `av_seek_frame` 会经自定义 AVIO 回调做**同步 HTTP Range 取流**，在 UI 线程调用就是
  "UI 线程做网络 I/O"（与下面 appfreeze 那条同源约束）；而且它会与解码线程并发操作
  同一个 `AVFormatContext`（数据竞争）。现在拆成两步：
  1. `requestSeek(seconds)`：线程安全、非阻塞，只记 `pendingSeekSec_`；
  2. `nextFrameRgba()` 在**解码线程**上先执行排队的 seek 再解码，结果写进
     `FrameInfo.seekApplied / seekedToSec / seekError`，宿主据此判断"跳转到底生效了没有"。
  设备实测（播放页双击两侧快进）：`seekTo ... queued=1` → `seekApplied to=16.3`，
  服务端进度 `pts=6.3` → `pts=21.1`；**修复前**软解下拖动进度条/±10s 完全没有反应。
  注意：排队 seek 要在"会话是否 eof"的判断**之前**执行 —— `seek()` 会清 `eof`，
  这样"播到结尾后往回跳"才能继续播。
- **画面比例（缩放模式）**：`EglRenderer::setScaleMode(ScaleMode)` 支持
  `Contain`（等比留黑边，默认）/ `Cover`（等比铺满并裁剪）/ `Stretch`（非等比铺满）/
  `Original`（1 视频像素 = 1 屏幕像素，装不下时退回 Contain）。
  实现是顶点着色器里的 `uScale` uniform（不重建顶点缓冲）：按「帧尺寸 → surface 尺寸」
  算缩放系数，`>1` 的部分由视口自然裁掉。两条要点：
  ①**不能只靠宿主把视频面调成画面同比例** —— `Cover`/`Stretch` 必须让画面溢出同一个视频面；
  ②渲染前**每帧重查 `eglQuerySurface`** —— 宿主会按比例改 XComponent 尺寸，
  沿用旧几何会让切比例后的画面被拉伸/错位。
  数值与宿主 ArkTS 的 `PlayerAspectMode`（contain/cover/stretch/original => 0/1/2/3）一一对应。
- **`DispatchTouchEvent` 非 null 是"参与输入派发"的开关，不是"手势判定"的实现** —— 实测结论：
  XComponent 之上的 ArkUI 透明层能收到触摸的前提，是原生回调**不为 `nullptr`**
  （为 `nullptr` 时框架不向该区域派发触摸，视频区手势全失效）；但回调本身**从未被调用**
  （hilog 只有 `RegisterCallback rc=0` 与 `OnSurfaceCreated`），因为 ArkUI 在应用层就消化了触摸。
  所以：手势判定留在 ArkUI 层，原生侧只需保证回调非空；想从原生侧接管才需要把事件转回 ArkTS。
- **软解拉帧必须带超时（否则会永久挂死）**：设备实测 4K 8-bit HEVC（「流浪地球2」，3840x1608）
  会出现**某次拉帧永不返回**的情况，宿主若只用 `softPulling` 互斥标志，就会永远停在最后一帧、
  既不报错也没有重试入口（违反"异常与超时必须到达终态"）。同环境下 4K 10-bit HEVC
  （「流浪地球」，3840x2160）可正常解码播放（约 10fps），因此这是**内容/解码器相关**的挂起，
  不是取流问题。宿主侧务必加看门狗（本项目 `PlayerPage` 为 20 秒）把它变成终态。
- **软解提速：哪些招有效、哪些实测无效（都带数据，别重复试）**
  同一模拟器、同一条目（1920×816 HEVC）实测，口径是 `softPlayOpen … decodeThreads=` 与逐帧
  `decodeMs= … fps= …`：

  | 做法 | 依据 | 实测 |
  |---|---|---|
  | `thread_count = 0`（自动按核数）+ `FF_THREAD_FRAME｜SLICE` | 解码器默认单线程，单核就是瓶颈；FFmpeg 头文件注明帧级并行"增加一帧/线程的延迟"，播放客户端始终有后续包，适用 | ✅ 线程 1→5，单帧 46–90ms→31–38ms，fps ≈5.6→**≈8** |
  | `sws_getContext(..., SWS_FAST_BILINEAR, ...)` | 每帧 YUV→RGBA + 缩放是仅次于解码的开销 | ✅（与上一条同批实测） |
  | `AV_CODEC_FLAG2_FAST`（"Allow non spec compliant speedup tricks"，`libavcodec/avcodec.h:355`） | FFmpeg 文档明确是"非严格符合规范换速度" | ❌ **无收益**：fps 8→8、单帧 29–37ms vs 31–38ms（噪声内），已回退 —— 本内容/本设备上瓶颈不在"严格性检查" |
  | `skip_loop_filter/skip_idct`（`AVDiscard`） | 跳过去块/变换可提速 | 未采用：会引入可见块效应，播放场景不值得 |
  | 拉帧循环接续方式：**自调度**（上一帧完成即排下一帧，下限 8ms；卡死判定独立成 5s 看门狗） | 原先 `setInterval(70ms)` + 在途互斥 ⇒ 实际周期 = max(70ms, 工作量)，实测 **115ms/帧（8.7fps）** | ✅ 小幅有效：**108ms/帧 → fps 8→9**（同条目、同口径）。说明"定时器空等"只占约 7ms，**大头仍在每帧的上传/渲染/NAPI 往返**（≈100ms − 解码 ~35ms）|
  | 纹理存储复用：尺寸不变时用 `glTexSubImage2D` 替代每帧 `glTexImage2D` | `glTexImage2D` 每帧**重新分配**一块 1259×535 RGBA（约 2.7MB）纹理存储 | ⚪ **本模拟器未测出差异**（fps 9→9，108ms→104ms/帧，噪声内）。保留理由：不重新分配是通用正确做法（真机 GPU 上省一次显存分配/丢弃），且不改变行为 —— 但**不宣称它是本轮的提速来源** |
  | （下一步）每帧其余开销 | 每帧总耗时仍约 100ms，解码只占 31–41ms，其余在 swscale、纹理上传、异步 NAPI 往返与渲染上 | ⏳ 未做：可选方向是减少每帧跨语言调用次数（把"拉帧+渲染"合并成一次调用）、或按渲染缓冲协商更小的上传尺寸 |

- **软解→硬解"反向升级"：设计与取舍（尚未实现，留档避免误判为遗漏）**
  需求里把它写成"另外可做"，本轮**有意未实现**，原因不是难，而是**无法在本环境验证**：
  关键是先分清"硬解为什么失败"，只有**可恢复的**失败才值得升级回去：

  | 硬解失败原因 | 是否可升级回硬解 | 依据 |
  |---|---|---|
  | 编码不支持（`5400106` / `801` / `VID_DEC_ERR-...-unsupport`） | ❌ 不可 —— 同一台机器的解码器能力不会变，升级回去必然再失败，只会造成软/硬反复抖动 | 设备实测：模拟器对 HEVC 一律报 `hevc-unsupport` |
  | 取流/IO 失败、解码器临时忙（`5400103` IO Error 等） | ✅ 可 —— 冷却一段时间后重试一次是合理的 | 这类失败与解码器能力无关 |
  | 网络/会话类错误（401/超时） | ⚠️ 视情况 —— 先修会话再谈解码方式 | 属于上层问题 |

  因此设计要点是：① 只对"可恢复失败"记录 `hardRetryEligible`；② 软解稳定播放一段时间
  （建议 ≥20s，避开"刚切换就抖回去"）后**最多尝试一次**；③ 尝试时按**当前 pts** 续接
  （同"无感切换"的位置口径），失败则永久放弃、不再重试；④ 切换过程同样不能闪错误页。
  **未实现的原因**：本环境能造出的失败都是"编码不支持"（即 ❌ 那一行），
  而 ✅/⚠️ 两类无法按需复现 —— 实现出来就是一段**无法验证**的分支。
  按本工程"每项改动都要有实测证据"的约定，留档待真机/可复现环境再做。

- **许可**：FFmpeg 为 LGPL-2.1+，必须动态链接并随包提供许可与源码获取方式（见 `native/third_party/NOTICE`）。
