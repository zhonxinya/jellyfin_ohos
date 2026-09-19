# FFmpeg 8.0 + 鸿蒙硬解（`--enable-ohcodec`）

本轮把内置的 FFmpeg 从 **7.1 升到 8.0**，并打开上游的 **OpenHarmony Codec** 支持，
使播放器可以经由 FFmpeg 使用**设备侧的编解码器**（OH_AVCodec）。

## 为什么必须升到 8.0

上游的鸿蒙编解码支持是 **FFmpeg 8.0** 才加入的（`libavcodec/ohdec.c`、`libavcodec/ohcodec.c`，
作者 Zhao Zhili，2025），7.1/7.0 里没有这套代码。对应开关是 `--enable-ohcodec`。

启用后：

- `libavcodec` 多出两个解码器：运行时名 **`h264_ohcodec`** / **`hevc_ohcodec`**
  （configure 里的**组件名**是 `h264_oh` / `hevc_oh`，但 `avcodec_find_decoder_by_name()` 匹配的是
  前者 —— 这一点本工程踩过：用组件名查找会返回 nullptr，"编译进了硬解却永远选不到"，而且表面上
  一切正常，只是悄悄退回自带解码器）；
- `libavcodec.so` 的 `DT_NEEDED` 里出现系统库
  **`libnative_media_vdec.so` / `libnative_media_codecbase.so` / `libnative_media_core.so`**
  （这就是"确实在用鸿蒙编解码框架"的硬证据）；
- 两种输出模式（见上游 `ohdec.c`）：
  - **buffer 模式**（本工程当前使用）：不配置 hw device，解码输出 NV12 的**普通 CPU 帧**，
    现有 `swscale → RGBA → EGL` 渲染链**不用改**；
  - **surface 模式**（零拷贝，后续可做）：`AV_HWDEVICE_TYPE_OHCODEC` + `native_window`，
    帧类型是新的 `AV_PIX_FMT_OHCODEC`，需要 surface 渲染。

## 构建侧改动

`scripts/build_ffmpeg_ohos.sh`：

| 改动 | 原因 |
|---|---|
| 版本 `7.1` → `8.0`（源码树同步替换） | 见上 |
| `--enable-ohcodec` | 打开鸿蒙编解码支持（configure 会去链那三个系统库） |
| 解码器列表加 `h264_oh,hevc_oh` | 组件名（运行时名见上） |
| **去掉 `--disable-postproc`** | 8.0 已移除 libpostproc，留着会直接报 `Unknown option` |
| `--disable-bsfs` 后补 `--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb` | ohdec 的 FFCodec 里 `.bsfs = "h264_mp4toannexb"`：MP4 的长度前缀格式必须转成 Annex-B 才能喂给 `OH_AVCodec`。不开这两个 filter，选到 ohcodec 也会解码失败 |
| 版本校验同时接受 `VERSION` / `RELEASE` | 官方发行包带 `VERSION`，上游 git 标签归档带 `RELEASE`（本仓库内置的是后者） |
| 部署前**清理上一次的 FFmpeg 库** | 升版本时 SONAME 会变（61→62、59→60、8→9、5→6），不清的话旧库会一直被打进 HAP（体积白涨、且永远不会加载）。只清 FFmpeg 自己的库，`libdav1d.so*` 不动 |

`scripts/pkg-config-shim.sh`：FFmpeg 8.0 把版本约束**加引号**整串传给 pkg-config
（`--exists --print-errors "dav1d >= 0.5.0"`），而 7.1 是拆成三个参数 —— 两种形式现在都能解析。

新的 SONAME（HAP 里打包的即是这一套）：

```
libavformat.so.62  libavcodec.so.62  libavutil.so.60  libswscale.so.9  libswresample.so.6
+ libdav1d.so.7（AV1 软解，见 docs/av1-and-transcoding.md）
```

## 播放侧改动

`native/feature/player/soft_decode_session.cpp` 的解码器优先级：

1. **H.264 / HEVC → `h264_ohcodec` / `hevc_ohcodec`**（鸿蒙编解码框架：真机上是**硬解**）；
2. AV1 → `libdav1d`（上游**没有** AV1 的 ohcodec 解码器：`ohcodec.h` 只映射 H.264/HEVC）；
3. 其余 → FFmpeg 自带解码器；ohcodec 打开失败时也回退到自带解码器（播放不因此中断）。

两个必需的细节：

- **`allow_sw=1`**：`*_ohcodec` 默认**只找硬件**编解码器
  （`OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE)`），找不到就直接打不开。
  打开 `allow_sw` 后，设备没有该编码硬解时会退回**系统软件**编解码器 —— 可用性优先。
- **`av_log` → hilog 的桥**（`player_log.cpp`）：在此之前 FFmpeg 的日志（`av_log`）
  **一个字节都到不了 hilog**，于是"解码器打不开"在设备上只能看到"打开失败"四个字。
  现在 warning 及以上会带 `ffmpeg[warn] / ffmpeg[error]` 前缀进日志，
  本轮正是靠它定位到模拟器没有 HEVC 的系统编解码器。

## 设备实测（DevEco x86_64 模拟器 + 本机 Jellyfin）

| 用例 | 结果 |
|---|---|
| 打开鸿蒙解码器（H.264 1080p，手动切到 FFmpeg 路径） | ✅ 日志：`ffmpeg[warn] Failed to get hardware codec video/avc, try software backend` → `softPlayOpen ok codec=h264 decoder=h264_ohcodec ... size=1920x1080` → `softPlayNextFrame #1 pts=0.000000 decodeMs=98`，**帧真的解出来了** |
| 打开鸿蒙解码器（HEVC 1080p） | ⚠️ 模拟器**没有 HEVC 的鸿蒙编解码器**：`Failed to get hardware codec video/hevc, try software backend` + `Failed to get software codec video/hevc` → 按设计退回 FFmpeg 自带 `hevc`（7 fps 正常播放，不中断） |
| 打包门禁 | ✅ `scripts/verify_hap_ffmpeg.sh` 通过（新 SONAME + `libdav1d.so.7` 依赖闭包完整） |
| AV1 / 转码 / H.264 回归 | ✅ 见 `docs/av1-and-transcoding.md`（AV1 走服务器转码或 dav1d；H.264 直连） |

> 模拟器只有**系统软件**编解码器（且 HEVC 连软件编解码器都没有），所以这里的
> `Failed to get hardware codec` 是**环境的限制**，不是代码问题：真机上 H.264/HEVC
> 一般都有硬件编解码器，`*_ohcodec` 会走硬解。判断某台设备到底有什么，看这行日志即可。

## 已知限制 / 后续

- **surface 模式（零拷贝）尚未接入**：现在走 buffer 模式（解码后 NV12 拷回 CPU 再 `swscale`）。
  接入 `AV_HWDEVICE_TYPE_OHCODEC` + `OH_NativeWindow` 可以省掉这次拷贝（`libavutil/hwcontext_oh.c`
  已经编进 `libavutil.so.60`，导出符号 `oh_device_create`）。
- **AV1 没有鸿蒙硬解**（上游未提供 av1_oh），AV1 仍靠服务器转码或 dav1d。
- **播放中手动切"软解"时画面无法上屏**（本轮实测到的既有缺陷，与 FFmpeg 升级无关）：
  在 AVPlayer 仍占用 XComponent surface 的情况下切到 FFmpeg，`eglSwapBuffers` 报 `0x12301`
  （几何从 1259x709 变成 629x354 / 320x180）。这正是 `native/feature/player/README.md` 里
  记录过的"软解与 AVPlayer 不能同时占用同一个 surface"约束；后续应在切换时按**当前 surface
  几何**重建 EGL surface（而不是沿用初始化时的几何）。
