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

## 已知限制

- 媒体库的**封面图**（`PrimaryImageItemId`）只在列表里暴露了是否存在，本页未做上传/更换；
  Jellyfin Web 也没有在"媒体库"页做这件事（它走条目图片管理），因此这里不做。
- 「路径」改动会让服务端重启目录监控（`AddMediaPath` / `RemoveMediaPath` 里的 `_libraryMonitor.Stop()`），
  所以对话框里给了「添加/移除后立即扫描」开关，默认开启以便新内容马上可见。
- 服务端要求路径在**服务器本机**真实存在，客户端无法预检，因此不做本地校验，直接让服务端报错。
