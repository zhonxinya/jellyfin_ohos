# JELLYFIN 鸿蒙客户端

基于 **ArkTS UI + C++ 核心** 的 HarmonyOS/OpenHarmony Jellyfin 客户端。

本项目是 [Jellyfin](https://jellyfin.org/) 的第三方客户端，仅连接**使用者自行部署**的 Jellyfin 服务器，
不包含、不提供任何媒体内容，也不内置任何服务器地址。

> [!IMPORTANT]
> **安装包需签名后才能使用。** 本仓库不包含任何签名证书与密钥，默认构建产出的是未签名 HAP，
> 仅可用于编译校验，**无法安装到真机或模拟器**（安装报 `code:9568320 error: no signature file`）。
> 安装前请先按[签名](#签名)章节配置签名材料。

## 开发环境

- DevEco Studio / HarmonyOS SDK（API 配套 `5.1.0(18)`，targetSdkVersion `6.1.0(23)`）
- Windows、HDC 与可用的真机或模拟器
- 可选：主机 g++ / clang++ / MSVC，用于运行 `native/core` 单测

## 快速开始

```powershell
# C++ 核心单测（主机侧，无需设备）
.\scripts\force-build.ps1

# 构建原生 Debug HAP（需本机配置 DevEco / 签名）
.\scripts\build.ps1

# 构建并安装到设备
.\scripts\build.ps1 -Run -DeviceId <device-id>

# Release 构建
.\scripts\build.ps1 -BuildMode release

# 设备管理（list / info / install / uninstall / start / stop / log）
.\scripts\install.ps1 -Action list
```

首次构建前请在 `native/app/build-profile.json5` 配置本地签名（`signingConfigs`），
勿将证书与密码提交到仓库；模板见根目录 `build-profile.json5.template`。

## 工程结构

```text
native/
  app/           # Stage 应用（ArkTS / hvigor），hvigor 工程根目录
  core/          # C++：HTTP、Session、Jellyfin API
  player/        # C++：硬解优先 + FFmpeg 软解兜底
  napi/          # NAPI 桥
  third_party/   # 开源依赖与 NOTICE
scripts/         # 构建、单测与设备脚本
```

## 当前能力

- 服务器配置、登录会话（经 C++ NAPI）
- 首页 / 媒体库 / 搜索 / 详情
- 播放页（硬解优先，FFmpeg 软解路径可对接 third_party）
- 设置与管理端页面（媒体库、用户、设备、插件、任务、播放设置等）

包名：`com.zhonxinya.jellyfin_hmos_flutter`

## 测试

`native/core` 的单测为主机侧测试，不依赖 HarmonyOS SDK 与设备：

```powershell
# 本机（Windows）：g++ / clang++ / MSVC 任一可用即可
.\scripts\force-build.ps1
```

CI 在 ubuntu 上按同样的源码组合编译并运行全部单测
（见 [`.github/workflows/build.yml`](.github/workflows/build.yml) 的 `core-tests` 作业）。

## 签名

本仓库**不含任何签名证书与密钥**，默认构建产出未签名 HAP（`entry-default-unsigned.hap`），仅可用于编译校验。

需要安装到真机时，配置自动签名：

1. DevEco Studio 打开 `native/app/` 目录
2. `File → Project Structure → Signing Configs`，勾选 `Automatically generate signature`
3. 重新构建，产物为 `entry-default-signed.hap`，可用 `.\scripts\install.ps1 -Action install` 安装

签名材料由 DevEco 写入 `native/app/build-profile.json5`（该文件已被 `.gitignore` 排除，不会误提交）。
手工配置的模板见根目录 `build-profile.json5.template` 与 `local.properties.template`。

> `native/app/build-profile.json5` 是 hvigor 必需的工程配置（缺失会报 `0304035 Not Found`）。
> 无签名环境下可复制 `native/app/build-profile.ci.json5` 重建，但该文件不含 `signingConfigs`，
> 直接复制只能产出未签名 HAP。

## CI / 工作流

| 工作流 | 触发 | 作用 |
|---|---|---|
| [`build.yml`](.github/workflows/build.yml) | push / PR / 手动 | `core-tests`：主机侧编译并运行 C++ 单测；`build`：下载鸿蒙命令行工具链，无签名构建 debug HAP 并上传产物 |
| [`release.yml`](.github/workflows/release.yml) | `v*` 标签 / 手动 | release 模式构建 HAP，创建或更新 GitHub Release（产物为未签名 HAP，附带签名说明） |
| [`codeql.yml`](.github/workflows/codeql.yml) | push / PR / 每周 / 手动 | CodeQL 高级设置，扫描 actions / c-cpp / javascript-typescript，排除 `native/third_party` |

工作流使用 [`.github/actions/build-hap`](.github/actions/build-hap/action.yml) 复合 Action 统一准备工具链与构建：
CI 不注入任何签名材料，固定使用 `native/app/build-profile.ci.json5`，因此 CI 产物**未签名**、不可直接安装。
[Dependabot](.github/dependabot.yml) 按月跟踪 GitHub Actions 版本。

## 第三方组件

`native/third_party/` 以 vendoring 方式引入以下开源库，其著作权与许可证归各自作者所有：

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| [mbedTLS](https://github.com/MbedTLS/mbedtls) | 3.6.2 | Apache-2.0 或 GPL-2.0-or-later（双许可） | `https://` 服务器 TLS |
| [nlohmann/json](https://github.com/nlohmann/json) | 3.11.3 | MIT | JSON 解析 |

详见 [native/third_party/NOTICE](native/third_party/NOTICE) 与 [native/third_party/README.md](native/third_party/README.md)。

## 免责声明

1. 本项目为 Jellyfin 第三方客户端，与 Jellyfin 官方项目无隶属关系；"Jellyfin" 名称及相关标识的权利归其各自权利人所有。
2. 本项目**不包含任何媒体内容、不提供任何服务器**，需连接使用者自行部署并拥有合法授权的 Jellyfin 服务器方可使用。
3. 使用者应确保对所访问、播放、下载的内容拥有合法权利，并自行承担由此产生的全部法律责任。
4. 本项目按**"原样"（AS IS）**提供，不附带任何明示或暗示的担保；作者及贡献者不对因使用或无法使用本项目导致的任何损害承担责任。

## 许可证

[BSD 2-Clause](LICENSE)
