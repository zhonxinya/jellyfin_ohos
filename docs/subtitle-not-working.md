# 字幕无法使用 —— 根因与修复

## 现象

播放页的「音频/字幕」面板里，字幕**完全不可用**，表现为两种情形：

1. 面板只显示「关闭字幕」+ 一句「**该视频没有字幕**」——明明文件里有字幕轨；
2. 即使列出了字幕并选中，提示「字幕已加载」，但**画面上永远没有字幕**。

## 根因（两个独立缺陷）

### 缺陷一：字幕列表依赖宿主传参，多数入口拿不到

音轨/字幕面板的数据源是页面字段 `mediaStreams`，而它**只由 `DetailPage` 通过路由参数传入**
（`DetailPage.playItem` 的 `mediaStreams`）。从其它入口进播放页时该参数是空的：

- 「继续观看」直接进播放页（`ContinueWatchingPage.continuePlay`）
- 首页 / 播放列表 / 条目长按菜单的播放动作
- 短视频页的「去播放页」

于是面板显示「该视频没有字幕」，字幕功能整个消失。

设备实测对照（同一部片、同一台设备）：

| 入口 | 面板显示 |
|---|---|
| 详情页 → 播放 | 2 条 ASS 字幕（国配简体/繁体） |
| 「继续观看」→ 播放 | **该视频没有字幕** |

### 缺陷二：`addSubtitleFromUrl` 在本工程的用法下是**静默空操作**

这是"选中后仍看不到字幕"的原因。HarmonyOS SDK 的原话
（`@ohos.multimedia.media.d.ts`，API 12 起）：

> Add subtitle resource represented by url to the player. **the external subtitle must be set
> after fdSrc of the video resource is set** in an AVPlayer instance.

即该 API 要求视频源经 **`fdSrc`** 加载。而本工程走的是
`this.avPlayer.url = <网络地址>`（直连/转码流），**不是 `fdSrc`** ——
于是这个调用**不报错、Promise 正常 resolve**（所以上层代码以为"字幕已加载"），
但播放器**根本不去取那个 URL**：

- 服务端日志可证：客户端**从未发出过字幕请求**（`/Subtitles/N/Stream.*` 一条都没有）；
- `subtitleUpdate` 事件也永远不会来 → 依赖它的渲染路径永远拿不到文本。

排查中确认的另两条死路（都验证过，供后来者省时间）：

- **`setMediaSource` 也不行**：`MediaSource` 只有 `setMimeType` / `enableOfflineCache` /
  `setMediaResourceLoaderDelegate`，**没有任何字幕字段**。
- 该 API 的 `getTrackDescription()` 也不会因加载字幕而多出字幕轨 ——
  所以原实现里"用加载前后的轨道差集找新轨"的逻辑注定找不到。

## 修复

### 1. 播放页自己从 `PlaybackInfo` 取媒体流列表（缺陷一）

新增 `applyMediaStreamsFromPlaybackInfo()`：`playerOpen` 的返回里本来就带 `playbackInfo`，
其中的 `MediaSources[0].MediaStreams` 与服务端判定播放方式用的是同一份数据，
**永远存在且准确**（含 `Index`/`Codec`/`Language`/`DisplayTitle` 等面板需要的字段）。

不再依赖宿主传参，因此**从任何入口进播放页，字幕/音轨列表都对**。
（宿主传了值时以 `playbackInfo` 为准 —— 详情页传的是"当前条目"的流，
而实际播放的可能是另一集。）

### 2. 字幕改为**应用侧取文本 + 自行解析 + 按位置渲染**（缺陷二）

- 原生侧新增 `fetchSubtitleText(url)`：用 core 的 `HttpClient` 取回字幕文本。
  **安全约束**：只接受当前 Jellyfin 服务器下的地址（同源校验），避免变成任意 URL 抓取器。
- 新增 `common/SubtitleTrack.ets`（纯函数，可离线单测）：
  - `parseSubtitleTimestamp`：兼容 VTT 的 `hh:mm:ss.mmm` 与 SRT 的 `hh:mm:ss,mmm`；
  - `stripSubtitleMarkup`：剥离 ASS 覆写块（`{\blur3\fad(500,500)...}`）、
    VTT 内联标签（`<i>` / `<c.foo>`）、`\N` / `\h` 转义；
  - `parseSubtitleVtt`：容错解析（坏行跳过，不整段失败）；
  - `subtitleTextAt`：**二分查找**取当前应显示的字幕（字幕上千条、每秒调用，线性扫描有可感开销）。
- 播放页在 `refreshState()` 里按 `positionMs` 驱动 `syncDrawnSubtitle()`，
  复用既有的 `subtitleText` 自绘路径（原生 SURFACE 上本来也画不了文本）。

### 3. 顺带修正的两处

- 「关闭字幕」的选中态改为**只看 Jellyfin 字幕流索引**。原先还带 `avSubtitleIndex < 0`，
  而应用自绘时 `avSubtitleIndex` 是一个负数哨兵（`kSubtitleLoadedNoTrack = -9`）——
  会把「关闭字幕」与所选字幕**同时打勾**。
- 图形字幕（PGS/VOBSUB）在面板里如实提示"本机暂不支持"，而不是让用户等一个不会来的字幕。

## 验证

### 解析器（离线，Node 跑同一份逻辑）

7 项断言全通过：条数、ASS 样式块剥离、HTML 标签剥离、多行合并、
SRT 逗号时间戳、区间外为空、二分查找边界（半开区间 `[start, end)`）。

再用**真实字幕文件**（服务端取回的 126KB VTT）核对：

```
文件中时间轴行数 = 1689
解析条数        = 1689      ← 零丢失
```

### 设备实测（模拟器 `Pura70Pro` / HarmonyOS 6.1.1(24)）

| 项 | 结果 |
|---|---|
| 面板提示 | `字幕已加载（1689 条）` |
| 勾选态 | 「国配简体中字」✓，且**未**同时勾选「关闭字幕」 |
| 画面字幕 | 连续采样正常随播放显示：`- 没这人 你打错了 - Angel`、`Linna Dolly Linlin 都没有`、`我是老恭 出来呀 保证有你好处` … |
| 「该视频没有字幕」 | 不再出现（该文案只在确实无字幕流时显示） |

> 采样期间有过「(无)」的时刻 —— 该片字幕**并非连续铺满**（间隙是正常的），
> 这一点一度让我误判为"渲染失败"。判定字幕是否工作时，要么多采样几次，
> 要么核对字幕文件在该时间点是否真有内容。

## 排查记录（可复用）

1. **`addSubtitleFromUrl` 的失败是静默的**：不抛异常、Promise 正常 resolve。
   判定它是否真的生效，唯一可靠办法是看**服务端是否收到字幕请求** ——
   客户端"以为加载了"和服务端"从没被请求"可以同时成立。
2. **别把"面板显示已加载"当成字幕可用**：那是我们自己的 `trackNote` 文案，
   与播放器真实状态无关。本次两个缺陷各让这句提示骗过一次。
3. **先核对数据再怀疑渲染**：连续采样看到「(无)」时，我一度怀疑渲染层级被 SURFACE 遮挡；
   实际把真实字幕文件拉下来跑一遍解析器（1689 = 1689）就排除了解析问题，
   再对照时间点才发现只是字幕间隙。
4. 判断"这份字幕到底有没有内容"最快的办法：直接把服务端的
   `/Videos/{id}/{msId}/Subtitles/{index}/Stream.vtt?api_key=…` 拉下来看。
