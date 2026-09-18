# Jellyfin 鸿蒙客户端 v1.0.0（初版）

基于 **ArkTS UI + C++ 核心** 的 HarmonyOS/OpenHarmony Jellyfin 第三方客户端首个正式版本。

连接你**自行部署**的 Jellyfin 服务器，浏览媒体库并播放。本应用不包含、不提供任何媒体内容，
也不内置任何服务器地址。

## 本版能力

- **连接与登录**：服务器地址规范化（末尾斜杠 / http 与 https / 反向代理子路径）、认证、
  多服务器切换、设备标识按安装持久化（服务端不会因反复登录堆积重复设备）
- **浏览**：首页（继续观看 / 最新 / 下一集…）、媒体库、合集、播放列表、搜索（防抖 + 分页 +
  搜索提示）、筛选与排序、详情页、演员页
- **播放**：系统 AVPlayer 硬解优先，**硬解失败自动回退 FFmpeg 软解**；
  播放控制、进度条与手势调节、视频比例（适应 / 填充 / 拉伸）、音轨与字幕切换（含外挂字幕，
  切换不打断播放）、横屏全屏观看、锁屏、后台播放
- **状态同步**：播放开始 / 进度（节流）/ 暂停 / 结束上报，续播位置，收藏与已看标记
- **管理端**：媒体库、用户、设备、插件、任务、播放与转码设置等页面

## 产物怎么选

| 文件 | ABI | 用途 |
|---|---|---|
| `jellyfin_ohos-v1.0.0-arm64-v8a-unsigned.hap` | arm64-v8a | **真机**推荐，体积最小 |
| `jellyfin_ohos-v1.0.0-universal-unsigned.hap` | arm64-v8a + x86_64 | 真机 + DevEco 模拟器（x86_64 仅为模拟器需要） |

两个产物都是**未签名** HAP：本仓库不含任何签名证书与密钥，未签名包无法直接安装
（安装会报 `code:9568320 error: no signature file`）。请按 `SIGNING.txt` 自行签名
（DevEco Studio 勾选自动签名，或按 `build-profile.json5.template` 手工配置）。

环境要求：HarmonyOS，`compatibleSdkVersion 5.1.0(18)` 及以上，`targetSdkVersion 6.1.0(23)`，
设备类型 `phone`。

## 自带 FFmpeg（软解码）

本版把 FFmpeg **编译进应用**：`native/third_party/ffmpeg/source/` 是未经修改的 FFmpeg 7.1
源码（LGPL-2.1-or-later，动态链接、未启用任何 GPL 组件），`native/app/entry/libs/<abi>/`
是随仓库提交的预编译共享库，构建时链接并打进 HAP。安装后**不依赖设备上存在任何 FFmpeg 组件**。

发布前，两个产物都会经过 `scripts/verify_hap_ffmpeg.sh` 门禁校验：`libjellyfin_native.so`
的 `DT_NEEDED` 依赖闭包必须在包内完整（`libavformat` / `libavcodec` / `libavutil` /
`libswscale` / `libswresample` 的 SONAME 文件齐全），且库的 ELF 架构与 ABI 相符。

> 为什么值得单列：缺了 FFmpeg 的产物**不会编译失败、也能正常启动**，只有碰到硬解不了的
> 媒体（例如 4K HEVC）才会暴露"软解回落不可用"，属于静默能力缺失。因此把它做成发布门禁。

## 已知限制

- **软解会话只解码视频**：不输出音频、不解析字幕；播放页的轨道面板会明确提示这一点。
- **软解不支持从上次位置续播**：软解回退时会提示「软解暂不支持从上次位置续播，将从头播放」。
  硬解路径的续播正常。
- **续播位置受服务端策略影响**：Jellyfin 默认 `MinResumePct=5`、`MinResumeDurationSeconds=300`，
  观看不足 5% 或时长过短时服务端会丢弃续播点——这是服务端行为，不是客户端缺陷。
- **模拟器无法硬解 HEVC**：DevEco 模拟器（x86_64）对 HEVC Main10 等编码硬解失败，会自动回退
  软解；真机硬解能力取决于设备。
- **会话凭据存储**：访问令牌当前保存在应用首选项（preferences）中，尚未迁移到
  `@ohos.security.asset`（Asset Store Kit）；该迁移是已记录的待办项。
  令牌不会写入日志、异常文本或截图。
- **兼容性**：面向 Jellyfin 10.8.x 与 10.10.x 实测（收藏 / 已看 / Suggestions 等端点按
  「新式优先、404/405 回退旧式」处理），更老或更特殊的服务器版本未经实测。

## 第三方组件与许可

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| [mbedTLS](https://github.com/MbedTLS/mbedtls) | 3.6.2 | Apache-2.0 或 GPL-2.0-or-later | `https://` 传输 |
| [nlohmann/json](https://github.com/nlohmann/json) | 3.11.3 | MIT | JSON 解析 |
| [FFmpeg](https://ffmpeg.org/) | 7.1 | LGPL-2.1-or-later（动态链接） | 软件解码 |

完整来源、构建方式、LGPL 合规说明与分发清单见
[`native/third_party/NOTICE`](../native/third_party/NOTICE) 与
[`native/third_party/README.md`](../native/third_party/README.md)。

本项目以 [BSD 2-Clause](../LICENSE) 许可发布。

## 免责声明

本项目为 Jellyfin 第三方客户端，与 Jellyfin 官方项目无隶属关系；不包含任何媒体内容、
不提供任何服务器。使用者应确保对所访问、播放的内容拥有合法权利，并自行承担由此产生的
全部法律责任。本项目按「原样」（AS IS）提供，不附带任何明示或暗示的担保。
