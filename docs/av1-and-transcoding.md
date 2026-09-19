# AV1 播放与服务器转码：根因、修复与验收记录

本文记录本轮「修复 AV1 解码 + 实现服务器转码播放」的**实测证据**与设计取舍。
结论先给：

| 场景 | 结果 |
|---|---|
| AV1 本机软解（内置 dav1d） | ✅ 720p 可播，模拟器实测 **约 7 fps**（解码 38–53ms/帧，其余是 swscale + 纹理上传 + NAPI 往返）；**软解路径无音频** |
| AV1 服务器转码（H.264/HLS） | ✅ **首选方案**：服务端转出 h264/aac，客户端原生 HLS 播放（硬件解码 + 有声音） |
| 服务端转码不可用时 | ✅ 自动退回「直连 + 本机软解」，并在画面上说明原因（实测已触发） |
| H.264 / HEVC 直连或软解 | ✅ 无回归（H.264 走系统硬解；HEVC 1080p 软解实测 7 fps 稳定推进） |

---

## 1. AV1 为什么放不出来（根因）

设备现象（修复前，模拟器 + 自建 Jellyfin 10.8.12）：

- 系统 `AVPlayer` 解不了 AV1 → 报错 → 触发"自动回退软解"；
- 软解**打开成功**（`softPlayOpen ok codec=av1 ...`），但**一帧都出不来**：进度停在 0、
  画面纯黑，屏幕上只剩一句"已自动切换软解播放"；
- hilog 里**什么都没有** —— 因为当时"拉帧失败"这条路径没有任何日志。

根因（读源码 + 用**同一份 FFmpeg 源码与同一套 configure 选项**在主机上复现）：

FFmpeg 7.1 的 `libavcodec/av1dec.c` 在 `get_pixel_format()` 末尾有一段硬判断：

```c
    ret = ff_get_format(avctx, pix_fmts);

    /* check if the HW accel is inited correctly. If not, return un-implemented.
     * Since now the av1 decoder doesn't support native decode ... */
    if (!avctx->hwaccel) {
        av_log(avctx, AV_LOG_ERROR, "Your platform doesn't support"
               " hardware accelerated AV1 decoding.\n");
        avctx->pix_fmt = AV_PIX_FMT_NONE;
        return AVERROR(ENOSYS);          /* ← -38 Function not implemented */
    }
```

而"纯软解"的绕过分支是它上面那段 `for (int i = 0; pix_fmts[i] != pix_fmt; i++)` ——
它只遍历**硬件格式**。本工程的 FFmpeg 是 `--disable-hwaccels` 构建
（`HWACCEL_MAX == 0`，候选表里只剩软件格式），这个分支**永远进不去**。

主机复现（`native/third_party/ffmpeg/source` 原样配置 natively 编译 + 一个模仿
`SoftDecodeSession` 的最小解码程序）：

```
container=mov,mp4,m4a,3gp,3g2,mj2 codec_id=av1(225) size=1280x720
avcodec_find_decoder -> av1 (Alliance for Open Media AV1)
avcodec_open2 rc=0 ok threads=1
send_packet #1 FAILED rc=-38 Function not implemented
...
RESULT frames=0 packets=600 fatal=0        ← 600 个包，0 帧
```

也就是说：**FFmpeg 自带的 `av1` 解码器在本构建里是死路**，必须换一个真正的
软件 AV1 解码器。

## 2. 修法：内置 dav1d

- 源码内置：`native/third_party/dav1d/source`（dav1d 1.5.1，BSD-2-Clause）
- 交叉编译：`scripts/build_dav1d_ohos.sh`（arm64-v8a **含汇编**；x86_64 纯 C，因为
  dav1d 的 x86 汇编需要 nasm，本环境与 CI 都没有）
- FFmpeg 重编：`scripts/build_ffmpeg_ohos.sh` 新增 `--enable-libdav1d`
  （HarmonyOS 工具链没有 pkg-config，用仓库内 `scripts/pkg-config-shim.sh` 顶上，并按 ABI
  现场生成 `dav1d.pc`；FFmpeg 的构建指纹里**并入 libdav1d.so 的 sha256**，dav1d 一换必然重链）
- 播放侧：`SoftDecodeSession::PickVideoDecoder()` 对 AV1 **显式优先**
  `avcodec_find_decoder_by_name("libdav1d")`，并把选中的解码器名回给宿主
  （`softPlayOpen ... decoder=libdav1d pick=AV1 → libdav1d`）

同一主机复现程序改用 dav1d 后：

```
avcodec_find_decoder -> libdav1d (dav1d AV1 decoder by VideoLAN)
frame #1 fmt=yuv420p 1280x720 pts=0
...
RESULT frames=5 packets=8 fatal=0
```

设备实测（模拟器，AV1 720p MP4，1920×1080 缩到渲染缓冲 1259×708）：

```
softPlayOpen ok codec=av1 decoder=libdav1d pick=AV1 → libdav1d size=1280x720 decodeThreads=0 openMs=54
softPlayNextFrame #1   pts=0.000000 decodeMs=47
softPlayNextFrame #100 pts=4.125000 decodeMs=38 fps=7
softPlayNextFrame #600 pts=24.958000 decodeMs=36 fps=7
```

## 3. 顺带修掉的两个"黑屏/崩溃"根因

这一轮在验证 AV1 的过程中把软解路径另外两个真实缺陷也挖出来并修掉了（都有实测证据）：

### 3.1 RangeCache 淘汰策略会把"正在读的那一块"删掉 → 取流死循环（卡死）

**现象**：HEVC 1080p（MP4，moov 在文件末尾）解到第 10 帧后，某次拉帧 **20 秒不返回**，
宿主看门狗判"软解无响应"（修复前还会因此崩溃，见 3.2）。

**根因**：`RangeCache::evictLocked()` 原实现是"优先丢 `pos_` 之前的块，否则丢
`chunks_.begin()`（偏移最小的那块）"。而 MP4 的 moov 常在文件末尾，解复用器一开始就把
`pos_` 抬到 673MB 一带、缓存被远块填满；等它回头顺序读开头时：

1. 缓存里没有任何"`pos_` 之前"的块 → 走 `begin()` 分支；
2. `begin()` 恰好是**刚取回来的、正在读的第 0 块** → 立刻被淘汰；
3. 读不到 → 再取 → 再淘汰 …… 死循环。

**实测证据**（诊断日志，修复前）：一次播放里同两块位置被反复取上千次

```
player: rangeCache fetch#4554 begin start=0 end=1048575 pos=236814
player: prefetch next=236814
player: rangeCache fetch#4555 begin start=0 end=1048575 pos=236814
...
```

**修法**：淘汰时**绝不丢包含 `pos_` 的块**；没有"已读过"的块可丢时，丢**离 `pos_` 最远**
的那一块。

**主机单测**（`native/core/tests/test_range_cache.cpp`，可在主机直接跑）新增回归用例
`TestEvictionNeverDropsTheChunkBeingRead`：先跳到远处散点读把缓存填满，再回到开头读。

- 旧实现：`FAIL 从文件末尾回到开头读，内容仍然正确 -> 成功读取次数=0`
- 新实现：`All range cache tests passed`

**设备复测**：同一条 HEVC 1080p 现在稳定推进 ——

```
softPlayNextFrame #1   pts=0.000000 decodeMs=110
softPlayNextFrame #100 pts=1.650000 decodeMs=42 fps=7
softPlayNextFrame #200 pts=3.316688 decodeMs=38 fps=7
softPlayNextFrame #300 pts=4.983313 decodeMs=40 fps=7
```

### 3.2 宿主关闭软解会话时，正在飞的那次拉帧会踩到已释放对象 → cppcrash

`softPlayNextFrame` 是异步（libuv 工作线程），而"停止软解"跑在 UI 线程
（看门狗判卡死、退出播放页）。原来用 `unique_ptr` 单例，`softPlayClose()` 直接
`reset()` 就会把工作线程脚下的会话对象析构掉。faultlog 栈：

```
#02 std::__n1::mutex::lock()
#03 jellyfin::player::RangeCache::fetchIntoLockedRange(long, ...)
#04 jellyfin::player::RangeCache::read(unsigned char*, int, ...)
```

**修法**：单例改 `shared_ptr`，异步任务把会话引用**带进闭包**；`softPlayClose` 只把会话
从单例摘下（不再销毁），对象活到那次调用结束。

设备复测：同样的"卡死"场景下**不再崩溃**，而是到达终态并给出可诊断文案：

```
软解无响应已 23 秒（解到第 10 帧 · 卡在 readPacket 23.2s · 本次已读 1 包），已停止；可点「软解」重试或改看其它条目
```

（"卡在哪一步"来自新增的阶段快照 `softPlayStatus`，见下。）

## 4. 让这类问题以后能被看见（诊断能力）

| 新增 | 作用 |
|---|---|
| `SoftDecodeSession::stageSnapshot()`（`softPlayStatus` 暴露） | 拉帧卡住时能说出**卡在哪一步**：`receiveFrame` / `readPacket` / `sendPacket` / `swsScale`，以及该阶段已持续多久、本次已读多少包 |
| `softPlayNextFrame` 失败日志 | 此前只在成功时打日志，失败完全静默；现在首个失败立即打（带解码器名/帧数/已取字节），之后每 100 次一条 |
| `RangeCache` 慢取流 / 慢加锁日志 | >500ms 的取流与 >1s 的等锁都会留痕（"卡在网络"与"卡在锁"分得开） |
| 单帧 >500ms 的分段耗时 | `slowFrame totalMs= readMs= sendMs= recvMs= packets=` |
| 单次拉帧 >3s 的进度日志 | 拉帧**永不返回**时也能在日志里看到它在哪一段 |
| `playerOpen method=... url=<redacted>` | 明确记录本次走的是 DirectPlay / DirectStream / Transcode（URL 去掉查询串，不记录 `api_key`） |
| `player_log.h` 注入点 | `feature/player` 仍然不依赖 hilog（可整目录移植），日志由宿主接线 |
| 解码失败不再被当成 EOF | 一帧都没解出来 + 连续 ≥30 包被解码器拒绝 → 明确报错（而不是把整片读完再以 `eof` 收场） |
| 起播看门狗（20s） | AVPlayer 停在 `initialized` 永不前进时到达终态（服务端转码失败时实测就是这样） |
| seek 统一走带状态守卫的封装 | 非法状态下 seek 不再抛 `5400102` 给用户看，而是记下来、`prepared` 后补做 |

## 5. 服务器转码播放（实现）

### 5.1 客户端现在会声明自己的能力

`/Items/{id}/PlaybackInfo` 带上 `DeviceProfile`（`native/core/api/device_profile.{h,cpp}`）：

- **直接播放**：h264 / hevc / vp9 / mpeg4 / vc1 …（与本工程 FFmpeg 启用的解码器对齐）
  + 常见音频与容器；**故意不含 av1**（本机解不动：系统不支持、软解仅约 7fps 且无音频）
- **转码目标**：`ts` 容器 + `h264` + `aac` + `hls` 协议（HarmonyOS 的 AVPlayer 原生支持 HLS，
  且能硬件解码 H.264）
- **字幕**：文本字幕声明为 External（与本工程"服务端转成 VTT 再交给 AVPlayer"的做法一致）；
  图形字幕（pgs/dvdsub）不声明（本工程不支持）

服务端响应（主机侧 API 实测，同一条目）：

| 条目 | 不带 DeviceProfile | 带 DeviceProfile |
|---|---|---|
| AV1 720p | `DirectPlay=True`，**无 URL** | `DirectPlay=False`，`TranscodingUrl=/videos/…/master.m3u8?VideoCodec=h264&AudioCodec=aac` |
| HEVC 1080p | 直连 | **直连（不变）** |
| H.264 1080p | 直连 | **直连（不变）** |

即：**只有本机真的解不动的编码才会被服务端转码**，其余保持原样（不回归）。

### 5.2 踩过的坑：Jellyfin 对"可直连"的条目**不返回任何地址**

实现保底判断时踩到的：`/Items/{id}/PlaybackInfo` 对可直连的条目实测响应只有
`MediaSources` + `PlaySessionId` —— **没有 `TranscodingUrl`、没有 `DirectStreamUrl`、
连 `ItemId` 都没有**（客户端是用 `/Videos/{id}/stream?static=true` 自己拼地址的）。

因此"响应里有没有地址"**不能**当作"能不能播"的判据：早期实现把它当作判据，结果每个直连
条目都会多做一次"去掉 DeviceProfile 重试"的请求（设备实测：普通 H.264 的日志里出现
`profileFallback=1`）。现在的判据是：

1. 有 `TranscodingUrl` / `DirectStreamUrl` → 可播放；
2. 否则看服务端的三面支持标记 `SupportsDirectPlay / SupportsDirectStream /
   SupportsTranscoding`，任一为 true → 可播放（地址可以自己拼）；
3. 三者全为 false → 才算"这个响应里没有可用地址"，此时才回退重试。

主机单测覆盖了这三种形态（`native/core/tests/test_device_profile.cpp`）。

### 5.3 保底路径

服务端可能装了但转不了码（没 ffmpeg、硬件加速配置不对、配额…）。两条保底：

1. **请求阶段**：带了 `DeviceProfile` 却拿不到任何可用 URL → 自动去掉 `DeviceProfile` 重试一次
   （退回改造前的"直连"行为）；
2. **播放阶段**：转码流（HLS）起播失败 → 关掉 `DeviceProfile` 重新请求 → 直连 → 系统硬解失败 →
   既有的"自动回退软解"接手（dav1d 能放 AV1）。只做一次，避免在两条路之间来回切。

## 6. 验收记录（设备：DevEco x86_64 模拟器，服务端：本机 Jellyfin 10.8.12）

关键的一行设备日志（新增的播放方式留痕，URL 已去掉查询串）：

```
playerOpen method=Transcode codec=av1  profileFallback=0 url=http://…/videos/<id>/master.m3u8?<redacted>   ← AV1：服务端转码
playerOpen method=DirectPlay codec=h264 profileFallback=0 url=http://…/Videos/<id>/stream?<redacted>       ← H.264：直连，无多余重试
```


| 用例 | 命令/脚本 | 结果 |
|---|---|---|
| AV1 软解出画面 | 搜索「万圣节」→ 播放 | 帧号推进到 #600+，`decoder=libdav1d`，画面亮度随帧变化（帧差 6.8，非静止黑屏） |
| AV1 服务器转码播放 | 同上 | 服务端会话 `transcoding=YES h264/aac reasons=['VideoCodecNotSupported']`，HLS 分片 `200`，位置 2.0s→7.0s 推进，画面有内容 |
| 转码不可用时的回退 | 服务端临时设成不可用的加速器（`qsv`，随后已还原为 `nvenc`） | 出现提示「服务器转码不可用（播放出错）→ 改用直接播放 + 本机软解…」，随后软解出画面（位置照常推进） |
| H.264 不回归 | 播放 1080p H.264 | 走系统硬解，无软解提示，画面正常 |
| HEVC 软解不回归 | 播放 1080p HEVC | 7 fps 稳定推进，无卡死、无崩溃 |
| RangeCache 回归 | 主机 `g++ … test_range_cache.cpp` | 全部通过（含新增用例；旧实现该用例失败） |
| DeviceProfile 单测 | 主机 `g++ … test_device_profile.cpp` | 全部通过（含"直连条目无 URL 仍算可播放"） |
| 既有主机单测 | `scripts/force-build.ps1` 覆盖的各套 | 全部通过（url_util / playback_resolve / http_response / image_url / items_query / library_admin / player_engine / range_cache / device_profile） |

> 说明：本机 Jellyfin 原先的硬件加速探测缓存里认为"GPU 能解 AV1"，导致转码任务用
> `-hwaccel cuda -c:v av1` 启动即失败（RTX 2060 没有 AV1 硬解）。重新探测后服务端改用
> **软件解 AV1 + NVENC 编码 H.264**，转码正常。若你的服务器也出现"转码一启动就失败"，
> 检查 Jellyfin 的「控制台 → 播放 → 转码 → 硬件加速」并重启服务端让它重新探测。

## 7. 已知限制

- **软解路径没有音频**（`feature/player` 不含音频输出，需宿主接 `OH_AudioRenderer`）。
  因此 AV1 在"只能软解"的设备上是有画面无声音的；**首选仍是服务器转码**。
- 模拟器上 dav1d 为**纯 C 编译**（无 nasm），720p 约 7 fps；真机 arm64 带汇编，会明显更好。
- 起播 7 fps 的一部分开销不在解码（解码 36–53ms/帧），而在 swscale + 纹理上传 + 每帧一次
  NAPI 往返（历史记录里 1080p HEVC 同样约 100ms/帧）。
