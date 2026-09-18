# 设置：三类设置与各自的存储位置

本应用的「设置」页混着三类**完全不同**的设置，改错类会出问题，所以这里先把它分清。
每一类在服务端的落库位置、端点、以及"改动会不会影响别的客户端"都不一样。

| 类别 | 存在哪 | 读写端点 | 影响范围 | 本应用的页面 |
| --- | --- | --- | --- | --- |
| **账号偏好**（`UserConfiguration`） | 服务器上你的**用户记录** | `GET /Users/{id}` + `POST /Users/{id}/Configuration` | 只影响你这个账号，换设备登录同一账号也生效 | 设置 → 显示/播放/首页与音频/字幕 |
| **服务器级设置**（`ServerConfiguration`） | 服务器配置 | `GET /System/Configuration` + `POST /System/Configuration` | 影响所有用户、所有客户端 | 设置 → 控制台 → 常规/播放/网络/媒体库显示… |
| **媒体库选项**（`LibraryOptions`） | 媒体库目录下的 `options.xml` | `GET /Library/VirtualFolders` + `POST /Library/VirtualFolders/LibraryOptions` | 只影响这一个媒体库 | 设置 → 媒体库 → 媒体库选项 |

## 三类设置都是"整体替换"，必须 GET 全量 → 改 → POST 全量

三处服务端的写法都是**直接赋值**，不是字段合并：

| 端点 | 服务端实现 |
| --- | --- |
| `POST /Users/{userId}/Configuration` | `UserManager.UpdateConfigurationAsync` —— 把提交对象的**每个**字段抄进用户记录 |
| `POST /System/Configuration` | `ConfigurationController.UpdateConfiguration` → `ReplaceConfiguration` |
| `POST /Library/VirtualFolders/LibraryOptions` | `CollectionFolder.UpdateLibraryOptions` → `SaveLibraryOptions` |

而反序列化一个"只带部分字段"的 JSON 时，没带的字段会变成 **C# 构造函数默认值**。
所以"只改一个开关"却发送 `{ "HidePlayedInLatest": true }`，会把其余 13 个用户偏好一起重置：

```
EnableNextEpisodeAutoPlay = true     RememberAudioSelections = true
RememberSubtitleSelections = true    HidePlayedInLatest = true
PlayDefaultAudioTrack = true         DisplayMissingEpisodes = false
DisplayCollectionsView = false       EnableLocalPassword = false
OrderedViews / GroupedFolders / MyMediaExcludes / LatestItemsExcludes = []
AudioLanguagePreference / SubtitleLanguagePreference = null
SubtitleMode = Default
```

（逐项抄自 `MediaBrowser.Model/Configuration/UserConfiguration.cs` 的构造函数。）

**本应用的约定**：账号偏好一律走 `patchUserConfiguration`
（`native/core/api/account_api.cpp`）：原生侧先 `GET /Users/{id}` 取当前 `Configuration`，
把增量合并进去，再整体提交。这样调用方（ArkTS 页面）只需给出"我改了哪几个字段"，
不存在漏字段把别人配置重置的可能。媒体库选项与服务器级设置同理，只是合并发生在页面里。

## 修掉的一个真 bug：所有账号偏好开关都没保存成功

旧实现把账号偏好 POST 到 `/Users/Configuration?userId=<id>`。10.8.12 上的路由是
`UserController` 的 `[HttpPost("{userId}/Configuration")]`，也就是 `/Users/{userId}/Configuration`：

```
POST /Users/Configuration?userId=a8b1…  -> HTTP 400（userId 落在路由段上，值成了字面量 "Configuration"，Guid 绑定失败）
POST /Users/a8b1…/Configuration         -> HTTP 204
```

也就是说「隐藏已播放的最新项」「自动播放下一集」「记住音频选择」「显示缺失的剧集」，
以及字幕页的三个字段，**以前都只改了界面、没有存到服务器**。现在端点写对，
并且改成"取当前配置 → 合并 → 整体提交"。

## 设备实测（真实 Jellyfin 10.8.12）

| 项目 | 证据 |
| --- | --- |
| 账号偏好可写、可复原、无副作用 | 切「自动播放下一集」→ 服务端该字段翻转，**变化的字段只有它**；切回后与初始配置零差异 |
| 媒体库顺序 | 「首页与媒体库」把第 1 项下移并保存 → 服务端 `OrderedViews` 等于"前两项交换"的精确期望值，且只改了这一个字段；复原后零差异 |
| 优先音轨语言 | 选择 `chi` → 服务端 `AudioLanguagePreference='chi'`，只改这一个字段 |
| 默认音轨开关 | 切「优先播放默认音轨」→ 服务端 `PlayDefaultAudioTrack=false`；复原后零差异 |

## 各页面覆盖的字段

| 页面 | 覆盖的 `UserConfiguration` 字段 |
| --- | --- |
| 设置（首页） | `HidePlayedInLatest`、`EnableNextEpisodeAutoPlay`、`DisplayMissingEpisodes` |
| 设置 → 首页与媒体库 | `OrderedViews`、`LatestItemsExcludes`、`MyMediaExcludes`、`GroupedFolders`、`DisplayCollectionsView` |
| 设置 → 音频 | `AudioLanguagePreference`、`PlayDefaultAudioTrack`、`RememberAudioSelections` |
| 设置 → 字幕偏好 | `SubtitleLanguagePreference`、`SubtitleMode`、`RememberSubtitleSelections` |

**没有覆盖 `EnableLocalPassword`**：开了它以后，支持该功能的客户端会要求输入本地密码，
而本应用没有"设置本地密码"的入口（`POST /Users/{id}/Password`），
贸然暴露这个开关会把用户锁在其它客户端之外。要支持就得连"设置/校验本地密码"一起做。

`OrderedViews` / `MyMediaExcludes` / `LatestItemsExcludes` / `GroupedFolders` 里放的都是
**媒体库视图 id**，来自 `GET /Users/{id}/Views`（普通用户也能调，与
`/Library/VirtualFolders` 那个管理员端点不同）。`OrderedViews` 允许只列一部分视图
（没列到的按默认顺序排在后面），所以界面会先把它与当前视图列表对齐再显示；
"有未保存的修改"也以对齐后的顺序为基线判断，避免一进页面就报脏。

## 服务器级的几页：媒体库显示 / 媒体库元数据 / NFO 设置 / 继续观看

「设置 → 控制台」下面这几页改的都是**服务器级**配置（影响所有用户与所有客户端）：

| 页面 | 服务端存储 | 读写端点 | 语义 |
| --- | --- | --- | --- |
| 媒体库显示 | `ServerConfiguration`（显示方式 / 图片落盘 / 扫描并发 / 监控延迟） | `GET/POST /System/Configuration` | 整份替换 |
| 媒体库元数据 | `ServerConfiguration.MetadataOptions[]` | 同左（整份） | 整份替换，但只有这一段会变 |
| NFO 设置 | `XbmcMetadataOptions`（key = `xbmcmetadata`） | `GET/POST /System/Configuration/xbmcmetadata` | 只替换这一段 |
| 继续观看 | `ServerConfiguration` 顶层五个字段（`MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` / `MinAudiobookResume` / `MaxAudiobookResume`） | `GET/POST /System/Configuration` | 整份替换，但只有这几个字段会变 |
| 品牌 | `BrandingOptions`（key = `branding`） | `GET/POST /System/Configuration/branding` | 只替换这一段 |

> 「继续观看」原来指向 `/System/Configuration`（整份配置的原始键值表），标题写着"继续观看"、
> 内容是服务器全部配置 —— 既看不懂也改不了。现在按上面五个字段做成表单（最短时长界面按**分钟**填，
> 服务端存秒）。
>
> 「品牌」原来也是原始键值表。它只有三个字段（`SplashscreenEnabled` / `LoginDisclaimer` /
> `CustomCss`），其中后两个只被 **Web 客户端**消费，页面上如实标注，避免用户以为改了手机会变样。
>
> 原来还有一条「Trickplay」指向 `/System/Configuration/trickplay` —— 实测 `trickplay` 与
> `trickplayoptions` **都是 404**，点进去只有一句报错；而 Trickplay（拖动预览缩略图）是 Web 特性，
> 本应用播放器不使用。与其留一条打不开的入口，不如去掉（要改在 Web 控制台的播放页里配）。

### 命名配置的 key 别猜，实测为准

`/System/Configuration/{key}` 只认 `ServerConfiguration` 上**带配置键的那几个属性**，
名字与属性名并不总是一致：

```
GET /System/Configuration/metadata          -> 200 {"UseFileCreationTimeForDateAdded":true}
                                               （这是 MetadataConfiguration，不是抓取器配置）
GET /System/Configuration/metadataoptions   -> 404
GET /System/Configuration/nfo               -> 404
GET /System/Configuration/xbmcmetadata      -> 200 {"ReleaseDateFormat":…,"SaveImagePathsInNfo":…}
```

所以：

- **元数据抓取器**（`ServerConfiguration.MetadataOptions`）**没有**可用的 keyed 路由，
  只能整份读写 `GET/POST /System/Configuration`；好在整份 GET → 原样 POST 的往返实测逐字节相同
  （45 个字段），只改一段是安全的；
- **NFO 设置**用 `xbmcmetadata`。本工程原来把它写成 `/System/Configuration/nfo`，点进去只有一句
  "此管理页面未开放该配置路径"（key 既不在 NAPI/页面的白名单里，服务端也不认）。

### 元数据页的两个细节

- 服务端**没有**"一次拿到所有条目类型可选项"的端点：`GetRepresentativeItemTypes(null)`
  只返回 `Series/Season/Episode/Movie`。所以这一页按内容类型各查一次
  `GET /Libraries/AvailableOptions`（8 次，在原生侧同一个后台线程里串行做完）再合并；
  合并逻辑是纯函数 `buildMetadataSettingsModel`，有主机单测；
- `MetadataOptions` 存的是**禁用列表**（+ 顺序列表）；某个条目类型**没有条目**时，
  服务端的"当前启用"要用 `AvailableOptions` 给的 `DefaultEnabled`（它正是服务端按全局配置算出的值）。
  界面两种来源按同一口径显示，所以"还没写过配置"不会被显示成"全都没启用"。

### 设备实测

| 项目 | 证据 |
| --- | --- |
| 媒体库元数据页 | 恒等保存后整份 `/System/Configuration` 逐字节相同；取消「电影」的一个元数据下载器并保存 → 整份配置里**只有 `MetadataOptions`** 段变化，该类型的 `DisabledMetadataFetchers` 恰好多一项；复原后零差异 |
| NFO 设置页 | 页面读到真实值（`ReleaseDateFormat=yyyy-MM-dd` 等）而不是 404；恒等保存后这一段逐字节相同；切「生成额外缩略图副本」→ 服务端 `EnableExtraThumbsDuplication` 翻转，整份配置里只有 `xbmcmetadata` 段、段内只有这一个字段变化；复原后零差异 |
| 继续观看页 | 页面显示 `MinResumeDurationSeconds=300` 换算成的 5 分钟；恒等保存后整份配置逐字节相同；把最短时长填成 6 分钟 → 服务端 `MinResumeDurationSeconds=360`，整份配置里只有这一个字段变化；复原后零差异 |
| 品牌页 | 页面读到真实值并显示「与服务器一致」；恒等保存后这一段逐字节相同；切「显示启动画面」→ 服务端 `SplashscreenEnabled` 翻转、这一段里只有这一个字段变化、整份 ServerConfiguration 未被触碰；复原后零差异 |

