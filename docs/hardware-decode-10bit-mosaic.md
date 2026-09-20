# 硬解花屏（10-bit 视频）——根因与修复

## 现象

播放页播放某部 **H.264 High 10（10-bit）** 的剧集时，画面**部分区域马赛克**（花屏），
但**不报错、进度条照常走**。

## 根因

系统硬解（AVPlayer）**解不了 10-bit H.264**，且失败是**静默**的 —— 不出错、不进错误态，
只把错误像素画到屏幕上。这带来两个后果：

1. 用户只能盯着花屏看（没有任何提示、也没有自动恢复）；
2. 本工程"硬解失败 → 自动回退 FFmpeg 软解"这条兜底**永远不会触发**（因为压根没"失败"）。

之所以会走到硬解，是因为能力声明**按编码名匹配、不区分位深**：

```
DirectPlayProfiles.VideoCodec = "h264,hevc,h265,..."   ← h264 不区分 8-bit / 10-bit
```

服务端于是把 `H.264 High 10`（`yuv420p10le`）也判成"可直连"，客户端拿到直连地址后
交给 AVPlayer 硬解 → 花屏。

设备实测（模拟器，源 `h264 High 10 / yuv420p10le / 1920x1080 / Level 5.1`）：

```
19:30:58  StreamBuilder → PlayMethod=DirectPlay, TranscodeReason=0      ← 硬解 10-bit → 花屏
19:31:30  StreamBuilder → PlayMethod=Transcode, TranscodeReason=DirectPlayError
                                                                        ← 约 30 秒后才报错、才回退
```

## 修复（两侧各挡一道）

### 1. 服务端侧：能力表补上位深约束（`native/core/api/device_profile.cpp`）

`DirectPlayProfile` **不支持** `Conditions`（模型里只有容器/编码字段），
位深约束只能写在 `CodecProfiles` —— 服务端在 `StreamBuilder.GetVideoDirectPlayProfile`
里用它的条件判定：条件不满足 → `videoCodecProfileReasons` 非 0 → 直连判定
`failureReasons == 0` 不成立 → 落到转码。

```json
"CodecProfiles": [{
  "Type": "Video",
  "Codec": "h264,hevc,...",
  "Container": "mp4,m4v,mov,mkv,...",
  "Conditions": [{
    "Condition": "LessThanEqual", "Property": "VideoBitDepth",
    "Value": "8", "IsRequired": false
  }]
}]
```

`IsRequired=false` 是必须的：它是"条件不满足即转码"，**不是**硬性拒绝
（置 true 会让不满足的内容完全不可播）。上限由 `ClientPlaybackCapabilities::maxVideoBitDepth`
控制，置 0 表示不声明该条件。

### 2. 客户端侧：10-bit 绝不交给系统硬解（`pages/PlayerPage.ets`）

只补服务端**不够**：`fallbackFromTranscode`（转码流起播失败 → 回退直连）会**去掉 DeviceProfile**，
服务端于是重新给出直连原文件 → 10-bit 又被硬解 → 花屏复现。

设备实测（修复了服务端、但客户端还没挡时的真实序列）：

```
20:44:21  Transcode   reason=[VideoBitDepthNotSupported]   ← 服务端侧已生效
20:45:56  DirectPlay  reason=[0]  url=.../stream.mkv       ← 回退直连 → 花屏复现
```

因此 `openPlayer` 里加守卫：解析本次 `playbackInfo` 的视频位深，
**位深 > 8 且拿到的是直连（非 HLS）地址**时，不交给 AVPlayer，直接走 FFmpeg 软解
（FFmpeg 的 h264 解码器能正确解 High 10）。

> 代价与取舍：软解路径**只解码视频、没有音频**（本工程软解的已知限制）。
> 这个分支只在"服务端转码也失败"的降级场景才会走到 —— 静默花屏比"无音频但画面正确"糟得多。
> 已把 `handlePlaybackFailure` / `startSoftPlay` 里重复的"是否转码流"判定收敛为
> `isTranscodePlayback()`，避免三处判据漂移。

## 验证（模拟器实测 + 服务端日志）

设备：HarmonyOS 模拟器 `Pura70Pro`（6.1.1(24)）。
样本：`h264 High 10`、`BitDepth=10`、`yuv420p10le`（系统硬解不支持）。

### 服务端判定（同一 profile 对照实验）

| DeviceProfile | 服务端结果 |
| --- | --- |
| 无 `CodecProfiles`（修复前） | `SupportsDirectPlay=True`，**不转码** → 客户端硬解 10-bit → 花屏 |
| 含 `VideoBitDepth <= 8`（修复后） | `SupportsDirectPlay=False`，转码，`TranscodeReasons=[VideoBitDepthNotSupported]` |

### 端到端播放（修复后）

```
20:51:49  StreamBuilder → PlayMethod=Transcode, TranscodeReason=VideoBitDepthNotSupported
          ffmpeg ... -codec:v:0 h264_nvenc ... -vf "...,format=yuv420p"     ← 输出 8-bit
          hls1/main/0.ts / 99.ts / 6.ts → Status Code 200                    ← 客户端取到分片
```

| 项 | 修复前 | 修复后 |
| --- | --- | --- |
| 判定序列 | DirectPlay → 约 30 秒后 DirectPlayError → Transcode | **仅 1 次 Transcode** |
| 直连次数 | 1（且回退路径还会再直连） | **0** |
| 播放推进 | 花屏期间仍在走 | 109s → 124s 正常推进 |
| 转码输出 | — | `format=yuv420p`（8-bit） |

主机单测 `test_device_profile` 新增 5 条断言（28 项全绿）：位深上限为 8、
`CodecProfiles` 非空、条件类型 `LessThanEqual`、`IsRequired=false`、
`maxVideoBitDepth=0` 时不声明条件。

## 排查记录（方法论）

- **不要把"某条记录看起来像"当成结论**：第一次看到该条目的转码理由是
  `SubtitleCodecNotSupported`（它带 2 条外挂 ASS 字幕），据此曾以为"位深不是原因"。
  真正定性靠的是**同一 profile 的对照实验**（去掉/加上 `CodecProfiles` 看服务端判定变化），
  以及**完整时序**（`DirectPlay` 在前、`DirectPlayError` 在后）。
- **`Profile=` 名不能用来判断有没有带 DeviceProfile**：不带 DeviceProfile 时，
  服务端会用会话的客户端名（实测同样记录为 `Jellyfin HarmonyOS Native`），
  需另找证据（如返回的是 `stream.mkv` 还是 `master.m3u8`）。
- 端到端验证看**服务端日志 + `/Sessions` 的 `TranscodingInfo`**，
  比看画面可靠（且本样本画面不适合人工查看）。
