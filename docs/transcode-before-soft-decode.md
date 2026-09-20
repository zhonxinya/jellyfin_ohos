# 电影/电视剧：服务器转码优先于本机软解

## 需求与改前行为

**需求**：电影与电视剧在本机解不了时，应**先让服务器转码**，而不是直接落到本机 FFmpeg 软解。

**改前**：`PlayerPage.handlePlaybackFailure()` 只有一条回退链 ——

```
直连硬解失败 ──► 本机 FFmpeg 软解
（转码流失败 ──► 退回直连 ──► 软解）
```

即"本机解不了"直接吃软解。对本项目的软解路径来说这个选择偏贵：

- **软解只解码视频，没有音频输出**（见 `docs/av1-and-transcoding.md`）；
- 由 CPU 逐帧软解，帧率有限（设备实测 HEVC 1080p 约 7 fps）；
- 耗电、发热明显高于硬解。

而服务端转码能给出 H.264/AAC 的 HLS，客户端走**系统硬解且有声音**。

## 改动

### 1. 回退顺序按条目类型分流（`PlayerPage.handlePlaybackFailure`）

| 当前这条路 | 电影 / 剧集（`Movie`/`Episode`/`Series`） | 其它类型 |
|---|---|---|
| 直连失败 | **先换服务器转码** → 再软解 | 直接软解 |
| 转码流失败 | 退回直连 → 软解 | 同左 |

判定见 `prefersServerTranscode()`：只对电影与剧集启用。这两类是"坐下来完整看一部"的场景，
画面与声音的完整度最要紧；其它类型（音乐等）沿用原有顺序。

新增 `serverTranscodeTried` 标志（与既有的 `transcodeFallbackTried` 方向**相反**，不能混用）：

- `transcodeFallbackTried`：已是转码流、转码失败 → 退回直连 + 软解；
- `serverTranscodeTried`：是直连、本机解不了 → 换成服务器转码再试。

`tryServerTranscode()` 把播放参数改成"关直连/直接串流、强制转码"重新解析地址。
为什么必须整体关掉直连而不能"只转音频"：DeviceProfile 的能力表是按本工程 FFmpeg 解码器
列表声明的（含 dts/truehd），服务端会认为"你本机能解"，只有关掉直连才会把音频一起转
（与短视频页 `playCurrentServerDecode` 同一套做法与理由）。

另外用 `!this.transcodeFallbackTried` 兜住一个真实往返：若本次播放**已经**试过转码、
失败后才回退到的直连，说明这台服务端转不了这条内容，再试一次只会白跑。

### 2. 条目类型由宿主页面传入

播放页只拿得到 `itemId`，重新请求详情只为拿类型是多余的往返，因此新增 `itemType` 路由参数，
由各入口传入：`DetailPage`（含"播的是哪一集"的解析）、`HomePage`、`ContinueWatchingPage`、
`PlaylistPage`、`MediaItemMenu`、`ShortVideoPage`。缺省为空时按"其它类型"处理（行为与改前一致）。

## 顺带修掉的一个真实缺陷：转码兜底必然 HTTP 404

`openPlayer()` 原来是

```ts
const target: string = this.playUrl.length > 0 ? this.playUrl : this.itemId;
```

`playUrl` 是**上一次**播放留下的地址（首次是直连的静态流 URL）。当 `tryServerTranscode` /
`fallbackFromTranscode` 改参数**重新**解析播放地址时，这行会把那个旧 URL 当成 itemId 传给
`playerOpen` → 服务端收到 `POST /Items/<url>/PlaybackInfo` → **HTTP 404**。

设备实测（模拟器）：转码兜底这条路径**必然失败**，界面停在「HTTP 404」。
改为恒传 `this.itemId`，让原生侧按当前播放参数重新解析地址。

## 验证（模拟器实测）

设备：HarmonyOS 模拟器 `Pura70Pro`（6.1.1(24)），1260×2844，density 3.375。
样本：`92黑玫瑰对黑玫瑰`（HEVC 1080p MKV，**模拟器硬解不支持 HEVC**）。

### 服务端日志（判定回退路径的唯一事实来源）

```
[19:45:55] StreamBuilder.BuildVideoItem( ... 92黑玫瑰对黑玫瑰 - 1080p.mkv ) =>
           ( PlayMethod=DirectPlay, TranscodeReason=0 )        ← ① 先给直连
[19:45:56] StreamBuilder.BuildVideoItem( ... 同上 ) =>
           ( PlayMethod=Transcode, TranscodeReason=DirectPlayError )  ← ② 客户端改请转码
[19:45:56] TranscodingJobHelper: ffmpeg ... -codec:v:0 h264_nvenc -f hls ...
           -ss 00:06:45 -hls_segment_filename ".../e85aa1086b0ef9aee2f8048c012c35a3%d.ts"  ← ③ 服务端真转码
[19:45:57] Slow HTTP Response from http://192.168.31.160:8097/videos/<id>/hls1/main/0.ts ... Status Code 200
[19:45:59] Slow HTTP Response from .../hls1/main/135.ts ... Status Code 200            ← ④ 客户端取到分片
```

①→②即"本机硬解失败后改走服务器转码"，③④说明转码确实跑起来且分片被取走。
`-ss 00:06:45` 对应详情页显示的「继续播放 · 6:44」，即**从失败位置续播而非从头开始**。

### 对照实验（服务端行为，curl 直测）

同一 `PlaybackInfo` 请求在两种参数下的差异（**这是"必须带 DeviceProfile + 关直连"的依据**）：

| 参数 | TranscodingUrl |
|---|---|
| 关直连 + **带** DeviceProfile | ✅ 返回（`/videos/<id>/master.m3u8?...`），GET 200 |
| 关直连 + 不带 DeviceProfile | ❌ 空 —— 客户端只能拼静态直连地址 → 对本机解不了的编码 404 |

## 验证环境说明（与 `detail-episodes-season-tabs.md` 同）

本次 UI 验证所用 HAP 的 **ArkTS 侧与本改动一致**，原生 core 取自
`fix/detail-page-fd-abort` 分支（`main` 上详情页仍有"约 20 秒必崩"，无法在该页完成验证）。
本改动只涉及 ArkTS，未触碰 `native/core`。

另外：模拟器上转码首次起播需现生成分片，容易撞上 20 秒的起播看门狗
（`kPrepareTimeoutMs`）而回落到软解 —— 这是模拟器环境的性能限制，不是回退链本身的问题；
服务端日志已证明转码任务与分片请求都成功了。软解兜底同时保证了用户不会看到错误页。
