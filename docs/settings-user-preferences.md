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

## 服务器级的几页

「设置 → 控制台」下面这几页改的都是**服务器级**配置（影响所有用户与所有客户端）：

| 页面 | 服务端存储 | 读写端点 | 语义 |
| --- | --- | --- | --- |
| 常规设置 | `ServerConfiguration` 顶层（服务器名 / 语言 / 元数据目录 / 日志保留 / 慢响应告警 …） | `GET/POST /System/Configuration` | 整份替换，只改列出的字段 |
| 网络 | `NetworkConfiguration`（key = `network`） | `GET/POST /System/Configuration/network` | 只替换这一段 |
| 转码 | `EncodingOptions`（key = `encoding`） | `GET/POST /System/Configuration/encoding` | 只替换这一段 |
| 媒体库显示 | `ServerConfiguration`（显示方式 / 图片落盘 / 扫描并发 / 监控延迟） | `GET/POST /System/Configuration` | 整份替换 |
| 媒体库元数据 | `ServerConfiguration.MetadataOptions[]` | 同左（整份） | 整份替换，但只有这一段会变 |
| NFO 设置 | `XbmcMetadataOptions`（key = `xbmcmetadata`） | `GET/POST /System/Configuration/xbmcmetadata` | 只替换这一段 |
| 继续观看 | `ServerConfiguration` 顶层五个字段（`MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` / `MinAudiobookResume` / `MaxAudiobookResume`） | `GET/POST /System/Configuration` | 整份替换，但只有这几个字段会变 |
| 品牌 | `BrandingOptions`（key = `branding`） | `GET/POST /System/Configuration/branding` | 只替换这一段 |
| 播放（服务器） | `ServerConfiguration.RemoteClientBitrateLimit` | `GET/POST /System/Configuration` | 整份替换，只改这一个字段 |

> 「播放」原来是一个 10 字段的通用编辑器，其中 8 个（续播阈值、特别篇显示、合集分组、
> 文件夹视图、慢响应告警）**已经在各自专页里**：同一个值能在两处改，单位还不一致
> （这边按秒、「继续观看」页按分钟）。现在只留服务器级的「远程码率上限」，
> 其余给页面入口指过去，标题也改成如实描述。

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

### 被删掉的三个页面：字段名写错 = 改了没效果

这三页都是"看起来能改、实际写不进去"的形态，已连同入口/页面一起删掉：

| 页面 | 问题 |
| --- | --- |
| `StreamingPage`（标题「流媒体」） | 读的其实是 `/System/Configuration/network`，而且 **4 个字段名在 10.8 里不存在**：`EnableRemoteControl` / `PublicHttpPort` / `InternalHttpPort` / `InternalHttpsPort`（真实字段是 `PublicPort` / `HttpServerPortNumber` / `HttpsPortNumber`，且没有 EnableRemoteControl）。服务端反序列化时静默忽略未知属性，所以界面上改了等于没改。这些内容现在都在「网络」页里，字段名逐个对着 `NetworkConfiguration.cs` 核过 |
| `TranscodingPage` | 也是 `/System/Configuration/encoding` 的字段编辑器，但只有 7 个字段、含一个不存在的 `AllowAv1Encoding`，而且**缺了最关键的硬件加速类型**。已被「转码」页取代（37 个字段里覆盖 32 个，字段名对着 `EncodingOptions.cs` 核过） |
| `UsersMetadataPage` | `/System/Configuration/metadata` 的原始键值表（只有 `UseFileCreationTimeForDateAdded` 一个字段），与新的「媒体库元数据」页重复，入口也不再有页面指向它 |

### 写这类页面时的三个坑（都是本轮设备实测踩到的）

1. **`InputType.Number` 会吞掉负号**：`EncodingThreadCount` 的 `-1` 表示"自动"，
   用数字键盘的输入框显示/回写成 `1`，一保存服务端就从 -1 变成 1（实测）。
   需要负数或小数的字段（线程数、立体声增益、色调映射的几个 double）必须用 `InputType.Normal` 再自己解析；
2. **只在服务端确实下发过该字段时才写回**（转码页的 `setIfPresent`）：
   这样旧/新版本里不存在的字段不会被客户端凭空补一个默认值写回去；
3. **开关别用 `@Builder` 包一层，直接用 `SettingCell`**（见下一节）。

### 开关：别自己用 `@Builder` 拼一个 `Toggle`，直接用 `SettingCell`

设置主页原来是自己写了个 `@Builder ToggleRow(...)`，里面放裸 `Toggle`。设备实测的毛病：

- 点「自动播放下一集」（原本**开**）想关掉它时，`onChange` 回调拿到的是**旧值 `true`**
  （probe 日志：`saveUserField EnableNextEpisodeAutoPlay=true`），于是把 `true` 又写回服务器，
  开关看起来"弹回去、点了没反应"（两行开关都复现过）；
- 换成直接放 `SettingCell`（`@Component`，`showToggle: true`）之后，同一次点击回调拿到的是 `false`，
  服务端正确翻转（主机实测：`True -> False`）。

另一件事：`Toggle` 在**创建时**就会用它拿到的值回调一次 `onChange` ——
也就是说"进设置页"这个动作本身会给每个"开着"的开关各触发一次回调。
这不是用户操作，所以 `saveUserField` 现在会先跟 `loadUserConfig` 记下的服务端值比对，
**相同就不发请求**（原来每次进页面都会白写 2 个 PATCH，而每个 PATCH 在原生侧是一次 GET + 一次 POST）。

### 设置主页里"算出来"的行会冻住：别再放进按值 `@Builder`

设置主页的分组卡片是本地 `@Builder SectionCard(标题, 图标, 行数组)`，行数组是**按值**传进去的。
`@Builder` 的按值参数不随状态刷新，于是**副标题由方法算出来的行会冻在第一次渲染的值上**。
设备实测两例：

| 行 | 现象 |
| --- | --- |
| 短视频模式 | 子页取消勾选一个库后返回，设置页仍显示「已选 2 个媒体库」；切页签也不会变（只有重启应用才对） |
| 主题与显示 | 在主题页选「浅色」返回后，这一行仍写着「深色 · 海洋蓝」 —— 而且它读的是本页 `aboutToAppear` 抄下来的副本，不是当前主题 |

修法（三件一起）：

1. 把「显示 / 播放 / 服务器」这三张卡改成用 `SectionCard` **组件**（`@BuilderParam` 内容）+ 行内
   `SettingCell`，动态字符串在**组件渲染时**求值，不再经过按值参数；
2. 外壳（`MainShell`）加一个 `settingsTabTick`：切到「设置」页签时自增，让设置页重算那几行；
3. 子页改完本地偏好后主动通知外壳：`ShortVideoPrefs.saveLibraryIds()` →
   `AppViewModel.notifyLocalPrefsChanged()` → 外壳 `settingsTabTick++`（与主题的
   `onThemeChanged` 同一套路）。有了这条，**返回设置页立刻就是新值**，不必等切页签。

另外把 `themeSubtitle()` 改成读 `AppViewModel` 的当前主题（并 `this.themeTick` 建立刷新依赖），
不再用本页的副本。

设备实测（同一处修复的两组证据）：

```
短视频模式：子页取消一个库 → 返回 → 设置行「已选 1 个媒体库，「视频」页按随机顺序连播」✓
            再勾回来 → 返回 → 「已选 2 个媒体库…」✓（修复前这两步都停在旧数字）
主题与显示：主题页选「浅色」→ 返回 → 「浅色 · 海洋蓝」✓；改回「深色」→ 返回 → 「深色 · 海洋蓝」✓
```

顺带记一条验收工具的改进：`uitest dumpLayout` 的 `Toggle` 节点带 `checked` 属性，
带上它就能直接断言开关状态（第 5 轮排查开关时只能靠"点了之后服务端变没变"间接推断）。
本轮据此验证了「操控偏好」的两个本地开关：切换 → 保存 → **重启应用** → 再进页面，开关状态保持 ✓。

### 回归巡检

`全部可逆`：翻转 → 断言服务端字段变化（且**只有这一个字段**变）→ 写回基线 → 断言零差异。

| 开关 | 结果 |
| --- | --- |
| 自动播放下一集（`EnableNextEpisodeAutoPlay`） | True → False ✓，只此一字段变化 |
| 隐藏已播放的最新项（`HidePlayedInLatest`） | True → False ✓ |
| 显示缺失的剧集（`DisplayMissingEpisodes`） | False → True ✓ |
| 优先播放默认音轨（音频页 `PlayDefaultAudioTrack`） | False → True ✓ |
| 记住字幕选择（字幕页 `RememberSubtitleSelections`） | False → True ✓ |

五项全部通过，最后一项收尾时 `UserConfiguration` 与基线**零差异**。


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

### 控制台的「日志」页：只取结尾，不整份拉进内存

原来这一页把 `/System/Logs` 的 JSON 当键值表列出来（文件名、大小、时间），**看不到内容** ——
而"看日志"才是这一页的用途。现在点开某个文件就能看结尾 256 KB。

为什么只取结尾：

- `SystemController.GetLogFile` 用的是 `File(stream, "text/plain")`，**没有** `enableRangeProcessing`，
  实测响应里也没有 `Accept-Ranges` —— 服务端只会给整份文件，没有 range/tail 可用；
- 文件还不小：本机实测 `log_YYYYMMDD.log` 一天就有 **20 MB**；
- 所以客户端把整份读进来（`HttpClient` 本来就有 32 MiB 上限）之后只用结尾一段：
  裁剪逻辑是纯函数 `TailBytes()`（`native/core/text_util.h`，有主机单测），
  它会退到合法的 UTF-8 边界、并从第一个换行之后开始，避免首行是半句话或被切成乱码。

好处是"交给 ArkTS 的字符串"始终 ≤ 256 KB，UI 不会因为日志变大而变卡；
界面上也如实写出文件总大小（"文件共 20.0 MB，这里只显示最后 256.0 KB"）。

### 控制台里的几个"通用列表页"改成按数据本身呈现

这几页原来都走同一套通用渲染（`AdminPageShell` + `AdminLoader`），有三处别扭：
一行一张卡片、标签固定 120vp；只显示一张**硬编码的英文键名单**；列表条目被压成一行字符串。
现在：

| 页面 | 改了什么 |
| --- | --- |
| 活动 | 每条 = 类型图标 + 名称 + 「类型中文标签 · **本地时间**」，按 `Severity` 着色；一次 50 条 + 「加载更多」（服务端 `startIndex`/`limit`）。原来连时间都不显示 —— `formatItem` 取的是 `LastActivityDate`/`AppName` 这些活动记录里根本没有的字段 |
| 系统信息 | 按「服务器 / 运行时 / 目录」三张卡呈现，字段名逐个对着 `MediaBrowser.Model/System/SystemInfo.cs` 核过；布尔显示成「是 / 否」；**服务端没下发的字段不显示**（不假装成"否"） |
| 本地媒体文件夹 | `/Library/MediaFolders` 返回的本来是**条目**（`Name`/`Path`/`CollectionType`…），原来只取 `Path` 用 📁 列出来，看不出路径属于哪个库；现在分成「媒体库」「其它文件夹」两组，行里是名称 + 路径 + 集合类型标签 |
| 通用键值页（排障用） | 整页一张卡 + 行间分隔线；短值并列、长值上下排列；常见字段有中文标签；**列出对象里的所有键**（原来只显示硬编码名单里的那些，名单外的内容会退化成"一整块 JSON"） |

活动记录的时间是服务端给的 UTC ISO（7 位小数，而 `Date.parse` 只认 3 位），
页面把它截到毫秒后转成**设备本地时间**，并在页头注明是本地时间。

### 控制台列表第二次收拾：计划任务 / 设备 / 用户

巡检这几个页面时又发现三处"信息摆错地方"：

| 页面 | 原来 | 现在 |
| --- | --- | --- |
| 计划任务 | 副标题是 `状态 · <32 位任务 id>` —— 那个 GUID 对用户没有任何意义 | `状态 · 上次 <本地时间> · 结果 · 耗时`（读服务端 `LastExecutionResult` 的 `StartTimeUtc` / `EndTimeUtc` / `Status`）；失败时多一行红字错误信息 |
| 设备 | 只有一堆设备卡片：没有总数、没有排序，`最后活动` 直接显示 UTC ISO 串 | 顶部「共 N 台设备（按最后活动时间排列）」+ 按最后活动倒序（设备会越攒越多，每次装应用都注册一台）+ 时间转本地时间 |
| 用户 | 当前登录账号的「删除」按钮是禁用的，但**没有任何说明** | 该行显示「当前登录账号（不能删除自己）」，不用点了才知道 |

服务端时间戳的显示统一收敛到 `common/TimeFormat.ets`（`short` / `full` / `durationSeconds` /
`durationLabel`）：UTC ISO → **设备本地时间**，并统一处理 7 位小数（`Date.parse` 只认 3 位）。
活动页原来那份局部实现也换成了它，避免几页各写一份。

### 设备实测

| 项目 | 证据 |
| --- | --- |
| 计划任务卡片 | 页面显示 `空闲 · 上次 2026-09-18 10:42 · 成功 · 耗时 3 秒`（服务端同一个 `StartTimeUtc` 是 `2026-09-18T02:42:23Z`，设备 +08:00 换算正确）；32 位任务 id 不再出现 |
| 设备列表 | 顶部「共 151 台设备（按最后活动时间排列）」，第一张卡片就是服务端 `DateLastActivity` 最大的那台；`最后活动` 显示成本地时间而不是 ISO |
| 用户列表 | 当前账号那一行出现「当前登录账号（不能删除自己）」，「管理员」标签仍在 |
| API 密钥（巡检顺带） | 整条写路径确认：界面新建 → 服务端出现该 Key → 点「撤销」→ 弹窗确认 → 服务端回到 0 个 |
| 计划任务启动（巡检顺带） | 界面点「启动」→ 服务端该任务的 `LastExecutionResult.StartTimeUtc` 更新（跑的是「清理日志目录」这种无副作用的日常清理） |

> 巡检期间顺手清掉了自己探针留下的设备登记（`probe-1`），服务端设备数从 151 回到 150；
> `probe1` 是这套验收工具登录时固定使用的设备 id，删掉它下次登录还会重建，所以留着。


### 设备实测

| 项目 | 证据 |
| --- | --- |
| 活动页 | 页头「最近 50 / 共 985 条记录」；最新一条名称与服务端一致；副标题形如 `停止播放 · 09-19 07:31`（服务端同一时刻是 `23:31Z`，设备 +08:00，换算正确）；滚到底点「加载更多（还有 935 条）」→ 变成「最近 100 / 共 985」 |
| 系统信息页 | 三张卡出现「服务器名称 / 版本 / 系统架构 / 数据目录 / 日志目录」等中文标签，值与 `/System/Info` 一致（`10.8.12`、`X64`、`/vol3/…/Jellyfin/data`），布尔显示为「是 / 否」，不再出现英文键名 |
| 本地媒体文件夹页 | 「媒体库（15）」「其它文件夹（1）」与服务端 16 个文件夹一一对应；行里同时有名称（`B站`）与路径，并带集合类型标签「电影」；不再是 📁 + 裸路径 |
| 通用键值页 | `/System/Configuration/metadata` 显示成 `UseFileCreationTimeForDateAdded = 是`（原来是一整块 `{"UseFileCreationTimeForDateAdded":true}`） |

### 设备实测

| 项目 | 证据 |
| --- | --- |
| 日志页 | 列出服务端 `/System/Logs` 的全部 4 个文件（名称/大小/时间与接口一致）；小文件 `Jellyfin.log`（110 B）→ "文件共 110 B，已完整显示" 且正文就是 `Stopping Jellyfin … / Starting Jellyfin …`；大文件 `log_20260919.log`（20.0 MB）→ "文件共 20.0 MB，这里只显示最后 256.0 KB"，正文节点 261 953 字符（≈256 KB）且内容是真实日志行 |

| 项目 | 证据 |
| --- | --- |
| 媒体库元数据页 | 恒等保存后整份 `/System/Configuration` 逐字节相同；取消「电影」的一个元数据下载器并保存 → 整份配置里**只有 `MetadataOptions`** 段变化，该类型的 `DisabledMetadataFetchers` 恰好多一项；复原后零差异 |
| NFO 设置页 | 页面读到真实值（`ReleaseDateFormat=yyyy-MM-dd` 等）而不是 404；恒等保存后这一段逐字节相同；切「生成额外缩略图副本」→ 服务端 `EnableExtraThumbsDuplication` 翻转，整份配置里只有 `xbmcmetadata` 段、段内只有这一个字段变化；复原后零差异 |
| 继续观看页 | 页面显示 `MinResumeDurationSeconds=300` 换算成的 5 分钟；恒等保存后整份配置逐字节相同；把最短时长填成 6 分钟 → 服务端 `MinResumeDurationSeconds=360`，整份配置里只有这一个字段变化；复原后零差异 |
| 品牌页 | 页面读到真实值并显示「与服务器一致」；恒等保存后这一段逐字节相同；切「显示启动画面」→ 服务端 `SplashscreenEnabled` 翻转、这一段里只有这一个字段变化、整份 ServerConfiguration 未被触碰；复原后零差异 |
| 网络页 | 恒等保存后 `network` 段逐字节相同；切「自动发现」→ 只有 `AutoDiscovery` 变化、整份 ServerConfiguration 未被触碰；「局域网子网」按行填两条 → 服务端数组正好两条；填 99999 端口 → 界面自己拦下（服务端端口仍是 8097）；复原后零差异 |
| 转码页 | 恒等保存后 `encoding` 段逐字节相同；切「启用限速」→ 只有 `EnableThrottling` 变化；用选择器把硬件加速改成「不启用」→ 服务端 `HardwareAccelerationType` 由 `nvenc` 变成空串、只有这一个字段变化；复原后 37 个字段与原值一致 |
| 常规设置页 | 14 个字段全部渲染出来且值来自服务端（`UICulture=zh-CN`、`QuickConnectAvailable=true` 等）；恒等保存后整份配置逐字节相同（差异为空） |
| 播放（服务器）页 | 新页面渲染出「远程播放码率上限」与相关设置入口；恒等保存后整份配置逐字节相同；填 12 → 服务端 `RemoteClientBitrateLimit=12000000`，整份配置只有这一个字段变化；复原后零差异 |

