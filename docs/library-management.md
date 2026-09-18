# 设置 → 媒体库管理

本页对照 Jellyfin 服务端源码（`docs/jellyfin-10.8.12`）实现「媒体库管理」的完整能力，
请求构造与响应解析集中在 C++（`native/core/api/library_admin_api.*`），ArkTS 页面只做展示与表单状态。

## 覆盖的服务端端点

| 能力 | 端点 | 参考源码 |
| --- | --- | --- |
| 媒体库列表 | `GET /Library/VirtualFolders` | `Jellyfin.Api/Controllers/LibraryStructureController.cs` |
| 新建媒体库 | `POST /Library/VirtualFolders?name&collectionType&refreshLibrary` | 同上（`AddVirtualFolder`） |
| 重命名 | `POST /Library/VirtualFolders/Name?name&newName&refreshLibrary` | 同上（`RenameVirtualFolder`） |
| 删除 | `DELETE /Library/VirtualFolders?name&refreshLibrary` | 同上（`RemoveVirtualFolder`） |
| 添加路径 | `POST /Library/VirtualFolders/Paths?refreshLibrary`，体 `MediaPathDto` | 同上（`AddMediaPath`） |
| 修改网络路径 | `POST /Library/VirtualFolders/Paths/Update`，体 `UpdateMediaPathRequestDto` | 同上（`UpdateMediaPath`） |
| 移除路径 | `DELETE /Library/VirtualFolders/Paths?name&path&refreshLibrary` | 同上（`RemoveMediaPath`） |
| 保存媒体库选项 | `POST /Library/VirtualFolders/LibraryOptions`，体 `UpdateLibraryOptionsDto` | 同上（`UpdateLibraryOptions`） |
| 扫描全部 | `POST /Library/Refresh` | `Jellyfin.Api/Controllers/LibraryController.cs` |
| 扫描单个媒体库 | `POST /Items/{itemId}/Refresh?metadataRefreshMode&imageRefreshMode&replaceAllMetadata&replaceAllImages` | `Jellyfin.Api/Controllers/ItemRefreshController.cs` |
| 元数据选项数据源 | `GET /Libraries/AvailableOptions?libraryContentType&isNewLibrary` | `LibraryController.GetLibraryOptionsInfo` |
| 语言/国家数据源 | `GET /Localization/Cultures`、`GET /Localization/Countries` | `LocalizationController.cs` |
| 服务器级媒体库设置 | `GET /System/Configuration`、`POST /System/Configuration` | `SystemConfigurationController.cs` |
| 封面信息 | `GET /Items/{itemId}/Images` | `ImageController.GetItemImageInfos` |
| 封面设为 URL 图片 | `POST /Items/{itemId}/RemoteImages/Download?type&imageUrl` | `RemoteImageController.DownloadRemoteImage` |
| 删除封面 | `DELETE /Items/{itemId}/Images/{imageType}?imageIndex` | `ImageController.DeleteItemImage` |

服务器级设置（媒体库显示方式、图片落盘约定、扫描并发与文件监控延迟）在
「设置 → 控制台 → 媒体库 → 媒体库显示」页（`LibraryDisplaySettingsPage.ets`）。
它和单个媒体库自己的选项是两回事：前者影响所有库与所有客户端，后者只影响一个库。
`POST /System/Configuration` 同样是**整体替换**（`ReplaceConfiguration`），
所以那一页也用"GET 全量 → 只改动过的字段 → POST 全量"的写法。

## 几个必须按服务端语义来做的点

### 1. 列表字段是 `Locations`，不是 `LibraryFolders`

10.8.12 的 `MediaBrowser.Model/Entities/VirtualFolderInfo.cs` 只有
`Name / Locations / CollectionType / LibraryOptions / ItemId / PrimaryImageItemId / RefreshProgress / RefreshStatus`。
早期版本的本页按 `LibraryFolders[].Path`、`MetadataPaths`、`RefreshMode`、`MetadataFetchers`、`ImageFetcher`、`Locale`
解析——这些字段在 Jellyfin 的响应里**根本不存在**，所以路径永远显示 0 个、刷新模式永远显示"完整刷新"。
现在按 `Locations` 解析，并在 `Locations` 为空时回落到 `LibraryOptions.PathInfos`。

### 2. 媒体库选项是**整体替换**

`MediaBrowser.Controller/Entities/CollectionFolder.cs`：

```csharp
public void UpdateLibraryOptions(LibraryOptions options) => SaveLibraryOptions(Path, options);
```

服务端不做字段合并，因此客户端必须把**服务端下发的完整选项对象**改完再整体回传。
本页的做法：打开时以服务端对象为底（`LibraryOptionSet`），保存时只覆盖本页改过的键，
其余键（包括本客户端还不认识的、新版本服务端才有的字段）原样带回。

### 3. 可空数组的 `null` ≠ 空数组

`LibraryOptions` 用 `JsonIgnoreCondition.WhenWritingNull` 序列化（`Jellyfin.Extensions.Json/JsonDefaults.cs`），
而这三项在服务端是"null 表示沿用全局配置"：

| 字段 | null 的语义 | 消费点 |
| --- | --- | --- |
| `MetadataSavers` | 用全局 `DisabledMetadataSavers` 判断 | `MediaBrowser.Providers/Manager/ProviderManager.cs` |
| `LocalMetadataReaderOrder` | 用全局读取器顺序 | 同上 |
| `SubtitleDownloadLanguages` | 用全局字幕语言设置 | `MediaBrowser.Providers/MediaInfo/FFProbeVideoInfo.cs` |

所以归一化时**不补空数组**（补了就会把"继承全局"变成"全部禁用"），
`LibraryOptionSet.isExplicit()` 用来区分"未显式配置"与"显式空列表"，
界面上对应两个开关：`限制字幕下载语言`、`元数据保存器`。

> 服务端的 `options.xml` 往返有个已知特性：`string[]?` 为 null 时写进 XML 再读回来可能变成空数组
> （实测这台服务器上几个历史媒体库读出来就是 `MetadataSavers: []`）。
> 这不是客户端能修的：本客户端按 null 回传，之后服务端重读配置文件时是否物化成 `[]`
> 由服务端决定；界面在那种情况下会显示"未勾选任何保存器"，用户重新勾选即可。
> 客户端侧保证的是：**没动过的字段不会被本次保存改写**（见上面的恒等保存验收）。

### 4. 路径走请求体，不走 query

`AddVirtualFolder` 的 `paths` 是 `[FromQuery, ModelBinder(typeof(CommaDelimitedArrayModelBinder))]`——
逗号分隔数组。媒体路径里完全可能出现逗号（`/media/电影, 收藏`），走 query 会被拆成两条不存在的路径。
控制器在 query 的 `paths` 为空时会改用请求体里的 `LibraryOptions.PathInfos`，所以客户端统一走请求体。

`RemoveMediaPath` 只能走 query，`EncodeQueryComponent` 会把 `/` 编成 `%2F`——
ASP.NET Core 的 query 解析会把它解码回 `/`，实测可用（见主机单测里的字面量断言）。

### 5. 只有 `Paths/Update` 能改网络路径

`LibraryManager.UpdateMediaPath` 是按 `PathInfo.Path` 去匹配已有条目、**只赋值 `NetworkPath`**，
它改不了真实路径。要换真实路径必须"移除 + 添加"，界面上也照此呈现（「网络路径」按钮 + 「移除」按钮）。

### 6. 语言是 `/Localization/Cultures`，值取三字母码

`LocalizationController` 只有 `Cultures` / `Countries` / `ParentalRatings` / `Options`，
**没有 `Languages`**（设备实测 `GET /Localization/Languages` 返回 404）。
`CultureDto` 里能当"语言"用的有三个字段，只有一个是服务端认的：

| 字段 | 中文示例 | 能不能当 `PreferredMetadataLanguage` |
| --- | --- | --- |
| `Name` | `Chinese` | ✗ 这是显示名 |
| `TwoLetterISOLanguageName` | `zh` | ✗ |
| `ThreeLetterISOLanguageName` | `chi` | ✓（`LocalizationManager` 用 `ThreeLetterISOLanguageNames.Contains(language)` 匹配） |

国家取 `CountryInfo.TwoLetterISORegionName`（实测与 `Name` 同值，例如 `CN`）。

### 7. 抓取器的"当前是否启用"

- `LibraryOptions.TypeOptions[]` 里**没有**某个条目类型时，服务端回落到全局 `MetadataOptions`
  （`BaseItemManager.IsMetadataFetcherEnabled`），所以界面不能用"库里没写 = 全关"来显示。
- `GET /Libraries/AvailableOptions` 返回的每个抓取器都带 `DefaultEnabled`，
  它正是服务端按全局配置算出的当前值（`LibraryController.IsMetadataFetcherEnabledByDefault`），
  因此"库里没有该类型条目"时用它作为勾选状态，与服务器实际行为一致。
- 保存时写入 `TypeOptions[].MetadataFetchers`（启用列表）并同步 `MetadataFetcherOrder`
  （服务端用 order 决定抓取优先级，只写启用列表会让顺序退回默认值）。

## 分层与可测性

```
ArkTS 页面（LibrariesAdminPage / LibraryPathsPage / LibraryOptionsPage）
   │  只做展示 + 表单状态，不拼 URL、不拼 query
   ▼
NAPI（native/napi/jellyfin_napi.cpp 的 library* 一组）
   │  取参数 → 构造 LibraryRequest → RunAsync 执行
   ▼
core/api/library_admin_api.{h,cpp}     纯函数：build*Request() + normalize*()
core/api/library_admin_client.cpp      薄封装：execute() / getVirtualFolders() / getLocalization()
```

`library_admin_client.cpp` 单独分出来是因为 `JellyfinApiClient` 的实现在 `api_client.cpp`，
会连带拉进 `session.cpp` / `http_client.cpp` / `http_tls.cpp`(mbedTLS)；
把依赖客户端的那一层分出去后，主机单测只链接 `library_admin_api.cpp` + `url_util.cpp` 即可，
不需要起服务器、也不需要设备。

主机单测：`native/core/tests/test_library_admin_api.cpp`
（已在 `.github/workflows/build.yml` 的 `core-tests` 与 `scripts/force-build.ps1` 中登记）。

## 设备验收记录（模拟器 + 真实 Jellyfin 10.8.12）

| 项目 | 观测到的证据 |
| --- | --- |
| 列表显示真实路径 | 卡片刻出 `/vol3/1000/Public/Media/…` 三条，与 `/Library/VirtualFolders` 的 `Locations` 逐条一致（修复前恒为"0 个路径"） |
| 列表显示封面 | 三个媒体库卡片各渲染出一个 64vp 的 `Image` 节点（该组件只在原生缓存拿到本地文件后才渲染，因此同时证明封面已下载落盘） |
| 恒等保存 | 打开「媒体库选项」不做任何修改直接保存 → 服务端 `LibraryOptions` 逐字节相同（27 个字段全保留） |
| 开关往返 | `EnableChapterImageExtraction` false→true→false，服务端两次读数与界面一致，**其它字段零改动** |
| 网络路径映射 | 在「路径」页写入 `smb://probe/nas-movies` → 服务端 `PathInfos[].NetworkPath` 随之变化，其它字段零改动；清空动作由主机单测覆盖（传空串 → 请求体里 `NetworkPath: null`） |
| 新建媒体库 | 临时库 `_验收库`（电影 / 一个路径）出现在服务端，`CollectionType=movies`、`Locations` 正确 |
| 加入 / 移除路径 | 服务端 `Locations` 由 1 条变 2 条再变回 1 条，界面同步显示 |
| 重命名 | `_验收库` → `_验收库B` → 改回，服务端列表随之变化 |
| 单库扫描 | 点「扫描 → 扫描新增与变更」后卡片显示「扫描中 N%」，服务端该库 `RefreshStatus=Active`、`RefreshProgress` 有值 |
| 缺少 ItemId 的库 | 未建过索引的库没有 `ItemId`，界面明确提示"该媒体库缺少 ItemId，无法单独扫描；请用「扫描全部」"，不发无效请求 |
| 删除 | 临时库删除后服务端列表与界面都不再出现，**原有三个媒体库（含 ItemId 与路径）完好** |
| 元数据保存器的默认值 | 把某库的 `MetadataSavers` 置空（=沿用全局）后在界面打开开关并保存 → 服务端得到 `["Nfo"]`（服务器默认启用的那项），而不是 `[]` |
| 服务器级设置页 | 恒等保存后 `/System/Configuration` 的 45 个字段逐字节相同；把 `DisplaySpecialsWithinSeasons` 改成 false 再改回 true，两次都只有这一个字段变化（其它字段零改动） |
| 封面（从 URL 设置 / 删除 / 复原） | 打开浮层显示 `Primary 960×540`；设为本地 HTTP 上的 400×300 图 → 服务端 `GET /Items/{id}/Images` 报 400×300、卡片重绘封面；删除 → 该库不再有 Primary、卡片显示首字占位块；再用同一机制把**原图**设回 → 960×540 且字节数与最初完全一致（669985） |

> ⚠️ 验收期间这台服务器被跑过一次 `POST /Library/Refresh`（用于让新建的库被索引），
> 大媒体库的完整扫描会持续较久，属于服务端正常行为。
> 封面验收用的是一台**只监听本机**的临时 HTTP 服务（`python3 -m http.server`）与本地生成的图片，
> 验收结束已停掉并清理；验收用的临时目录 `/tmp/dsh-probe-*` 也已删除。

## UI 模型

归一化后的 JSON（`data`）形状：

```
[
  {
    "name": "电影",
    "itemId": "3f2c…",
    "collectionType": "movies",          // 服务端用小写序列化枚举
    "locations": ["/media/movies"],      // 权威路径列表
    "pathInfos": [{ "path": "/media/movies", "networkPath": "smb://nas/movies" }],
    "refreshStatus": "",
    "refreshing": false,
    "refreshProgress": null,
    "hasPrimaryImage": true,
    "primaryImageItemId": "3f2c…",
    "options": { "EnableRealtimeMonitor": true, "TypeOptions": [ … ] }   // 原样可回传（PascalCase）
  }
]
```

- 外层是 camelCase 的 UI 模型；
- `options` 保持服务端的 PascalCase 键名，因为它要被**原样回传**，改键名会让回传丢字段。

## 封面（图片）

媒体库卡片上的「封面」会打开一个浮层（`LibrariesAdminPage.CoverSheet`）：

- 打开时先 `GET /Items/{itemId}/Images`，如实显示服务器上**当前有哪些图片、多大**
  （例如 `Primary 960×540`），而不是只知道"有没有"；
- 「从该地址设置封面」：把 URL 交给 `POST /Items/{itemId}/RemoteImages/Download`，
  **由服务器去抓取并保存**，客户端只发送地址 —— 图片不经过手机中转，
  也不需要客户端实现二进制上传；
- 「删除现有封面」：`DELETE /Items/{itemId}/Images/Primary`，删掉后卡片显示首字占位块。

**未实现：从手机本地图片文件设置封面。** Jellyfin Web 的"编辑图片"对话框里有本地上传
（`POST /Items/{itemId}/Images/{imageType}`，请求体是图片二进制），本应用没做，原因是：
本机的模拟器上没有可供选择器挑选的图片源，做出来是一条**无法验收**的链路。
要补的话需要三件事一起做：系统图片选择器接入、把选择结果拷进应用沙箱、
原生按二进制体 POST（现在的 HttpClient 只发 JSON 字符串体），并处理图片格式与体积上限。

## 已知限制

- 「路径」改动会让服务端重启目录监控（`AddMediaPath` / `RemoveMediaPath` 里的 `_libraryMonitor.Stop()`），
  所以对话框里给了「添加/移除后立即扫描」开关，默认开启以便新内容马上可见。
- 服务端要求路径在**服务器本机**真实存在，客户端无法预检，因此不做本地校验，直接让服务端报错。
- 从 URL 设置封面要求**服务器能访问该地址**（内网地址、需要鉴权的图床都可能失败），
  失败信息由服务端返回、界面原样展示。

