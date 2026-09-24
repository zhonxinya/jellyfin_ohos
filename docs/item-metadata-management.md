# 条目（影视）元数据管理

影片 / 剧集详情页操作区的「编辑元数据」入口（仅管理员可见），进入独立页面
`pages/ItemMetadataPage.ets`，可编辑字段、识别（远程搜索）、刷新元数据、管理封面。

请求构造与响应解析集中在 C++（`native/core/api/item_metadata_api.*`），ArkTS 页面只做展示与表单状态。
本页对照 Jellyfin 服务端源码（`docs/jellyfin-10.8.12`）实现，下面每一条服务端语义都标了出处。

## 覆盖的服务端端点

| 能力 | 端点 | 参考源码 |
| --- | --- | --- |
| 条目完整 DTO（表单回填 + 整体回传的底稿） | `GET /Users/{userId}/Items/{itemId}?Fields=…` | `Jellyfin.Api/Controllers/ItemsController.cs` |
| 编辑器下拉数据源 | `GET /Items/{itemId}/MetadataEditor` | `Jellyfin.Api/Controllers/ItemUpdateController.cs`（`GetMetadataEditorInfo`） |
| 外部 ID 提供方定义 | `GET /Items/{itemId}/ExternalIdInfos` | `Jellyfin.Api/Controllers/ItemUpdateController.cs` |
| 保存字段（整体替换） | `POST /Items/{itemId}`，体 `BaseItemDto` | 同上（`UpdateItem`） |
| 设置内容类型覆盖 | `POST /Items/{itemId}/ContentType?contentType=` | 同上（`UpdateItemContentType`） |
| 识别（远程搜索候选） | `POST /Items/RemoteSearch/{itemType}`，体 `RemoteSearchQuery` | `Jellyfin.Api/Controllers/ItemLookupController.cs` |
| 应用识别结果 | `POST /Items/RemoteSearch/Apply/{itemId}?replaceAllImages=` | 同上（`ApplySearchCriteria`） |
| 刷新元数据 | `POST /Items/{itemId}/Refresh?metadataRefreshMode&imageRefreshMode&replaceAllMetadata&replaceAllImages` | `Jellyfin.Api/Controllers/ItemRefreshController.cs` |
| 图片列表 | `GET /Items/{itemId}/Images` | `Jellyfin.Api/Controllers/ImageController.cs`（`GetItemImageInfos`） |
| 设为 URL 图片 | `POST /Items/{itemId}/RemoteImages/Download?type&imageUrl` | `Jellyfin.Api/Controllers/RemoteImageController.cs` |
| 删除图片 | `DELETE /Items/{itemId}/Images/{imageType}?imageIndex` | `ImageController.DeleteItemImage` |

后三个端点（图片列表 / 设为 URL 图 / 删除）**没有新写 core 代码**，直接复用了媒体库管理
已有的 NAPI（`libraryCoverInfo` / `librarySetCoverFromUrl` / `libraryDeleteCover`）——
它们是"对任意 itemId 的图片操作"，与"对媒体库"只是调用方不同。

## 权限

三个控制器（`ItemUpdateController` / `ItemLookupController` / `ItemRefreshController`）在服务端
都是 `[Authorize(Policy = Policies.RequiresElevation)]`，**只有管理员**能用。三处门禁：

1. 详情页操作区的入口 `AppIconButton` 包在 `if (AppViewModel.getInstance().isAdmin)` 里；
2. `ItemMetadataPage` 加载前再检查一次 `isAdmin`；
3. NAPI 侧 `RequireAdmin()` 兜底（即使被直接调用也返回 401）。

## 几个必须按服务端语义来做的点

### 1. `POST /Items/{itemId}` 是**整体替换**

`ItemUpdateController.UpdateItem` 把请求 DTO 的字段**逐个赋值**给条目，不做字段合并：

```csharp
item.Genres = request.Genres;      // 请求里没带 → null → 清空
item.Tags = request.Tags;
item.IsLocked = request.LockData ?? false;   // 没带 LockData → 静默解锁
item.ProviderIds = request.ProviderIds;
```

所以客户端**不能**只提交"被改过的字段"，必须以服务端条目原文为底、把用户改动合并进去再整体回传。
本页的做法：`getItemMetadata` 拿到的 `item` 原文存在 `rawItem` 里，
`MetadataDraft.buildBody`（`common/ItemMetadataModels.ets`）在原文之上覆盖改动过的键，
**原文里其它键（包括本客户端还不认识的、新版本服务端才有的字段）原样带回**。

两个"漏字段就出事"的地方：

- `LockData` 缺失 = 解锁。注意它与 `LockedFields` 不对称：
  `item.LockedFields = request.LockedFields` 外面**有** null 判断，所以 `LockedFields` 缺失会保留原值；
- `ProviderIds` 缺失会直接 **500**：`request.ProviderIds.ToList()` 没有 null 保护，
  而 `BaseItemDto.ProviderIds` 没有初始化器。core 的 `normalizeItemMetadataBody` 把它兜成空对象。
  另外服务端会**丢掉空字符串取值**（`if (string.IsNullOrEmpty(pair.Value)) Remove`），
  所以界面把某个外部 ID 清空 = 删掉这个键，是符合预期的。

### 2. 字段是**按 `Fields` 门控**的

`GET /Users/{userId}/Items/{itemId}` 的响应里，下面这些字段**不写进 `Fields` 就不返回**：

`ProviderIds`、`Genres`、`Tags`、`Studios`、`Overview`、`Taglines`、`ProductionLocations`、
`SortName`、`CustomRating`、`OriginalTitle`、`DateCreated`，以及 `Settings`
（它同时管 `PreferredMetadataLanguage`、`PreferredMetadataCountryCode`、`LockedFields`、`CriticRating`）。

"不返回" + "整体替换" = **静默清空**。所以 `kItemMetadataEditFields` 必须覆盖全部可编辑字段
（主机单测逐项断言了这一点）。未被门控的字段（`People` / `IndexNumber` / `RuntimeTicks` …）
也一并取回，回传时更完整。

### 3. `Studios` 必须是 `[{ "Name": "..." }]`

服务端取 `request.Studios.Select(x => x.Name)`，而界面把它当字符串列表编辑。
`normalizeItemMetadataBody` 会把 `["华纳"]` 这种写法转成 `[{ "Name": "华纳" }]`，否则服务端读到 `null` 名字。

### 4. `Taglines` 只保留第一条

```csharp
if (request.Taglines != null) { item.Tagline = request.Taglines.FirstOrDefault(); }
```

服务端条目只有一个 `Tagline` 字段，界面按单行文本编辑，回传成单元素数组。

### 5. `ContentType` 走**另一个端点**

`ContentType` 不在 `BaseItemDto` 上，`ItemUpdateController.UpdateItem` 也不处理它。
它由 `UpdateItemContentType` 按"条目所在**路径** → 内容类型"写进**服务器配置**
（`Configuration.ContentTypes`），所以没法跟其它字段一起整体替换，只能单独
`POST /Items/{itemId}/ContentType?contentType=`。空串 = 清除覆盖（回到从媒体库继承）。

### 6. 识别：`RemoteSearch` 的类型白名单里**没有 Episode**

`ItemLookupController` 的 10.8 端点只有 Movie / Trailer / MusicVideo / Series / BoxSet /
MusicArtist / MusicAlbum / Person / Book —— 分集元数据跟着剧走，不单独识别。
`remoteSearchTypeFor` 对不支持的类型返回空串，界面据此**隐藏**「识别」区而不是发一个必然 404 的请求。

搜索请求体里的两个细节：

- `IsAutomated` 显式写 `false`。`ItemLookupInfo` 的构造默认是 `true`，而服务端手动刷新
  （`ItemRefreshController`）同样写 `false`；手动识别必须保持一致；
- `ProviderIds` 非空时按外部 ID 精确查（改错 ID 后纠正就该用它），比按名字查准得多。
  `ItemId` 一并带上，让服务端继承该条目的元数据语言。

### 7. 应用识别结果是**破坏性**的

`ApplySearchCriteria` 会：

```csharp
item.ProviderIds = searchResult.ProviderIds;
RefreshFullItem(item, new MetadataRefreshOptions(...) {
    MetadataRefreshMode = FullRefresh, ImageRefreshMode = FullRefresh,
    ReplaceAllMetadata = true, ReplaceAllImages = replaceAllImages, RemoveOldMetadata = true,
    SearchResult = searchResult });
```

即"FullRefresh + 替换全部元数据 + 移除旧元数据"。**用户手改过的字段会被覆盖**，
所以界面在应用前弹 `ConfirmOverlay` 明确说明这一点，并给「同时替换图片」开关
（对应 `replaceAllImages`，默认关闭）。

### 8. 外部 ID 的显示名**不唯一**，要用 Key 消歧

服务端的 `ExternalIdInfo.Name` 是提供方**显示名**、`Key` 才是 `ProviderIds` 的键。
模型注释明说 Key 不保证跨类型唯一，而且同一个显示名会对应多条定义：

| 定义 | `Name` | `Key` | `Supports` |
| --- | --- | --- | --- |
| `TmdbMovieExternalId` | `TheMovieDb` | `Tmdb` | Movie |
| `TmdbBoxSetExternalId` | `TheMovieDb` | `TmdbCollection` | Movie / MusicVideo / Trailer |
| `ImdbExternalId` | `IMDb` | `Imdb` | Movie … |

电影会同时匹配前两条 → 界面上出现**两行同名 `TheMovieDb`**（设备实测确认）。
`ProviderIdEntry.build` 在显示名重复时补上 Key（`TheMovieDb（Tmdb）` / `TheMovieDb（TmdbCollection）`）区分。

同一个函数还要"补漏"：`ExternalIdInfos` 是**当前服务器配置的抓取器**给出的定义，
而条目原文里的 `ProviderIds` 可能含定义外的键（换过抓取器、手动写过）。
整体替换下漏掉任何一个键都会把它从条目上抹掉，所以定义外的键也要列出来
（标注 `xxx（未配置的提供方）`）让用户看见。

### 9. 会**回源抓取**的端点要用更长的读超时

识别 / 应用识别 / 刷新元数据这三类请求，服务端要**回源**去问 TMDb / TVDB 等外部提供方，
首查冷启动远超交互式请求的耗时。设备实测（同一台 10.8.12 服务器、同一部电影）：

| 客户端读超时 | 结果 |
| --- | --- |
| 15s（交互式 `Api()`） | ~14s 落到 `Read timeout` |
| 60s | ~64s 仍失败 |
| 180s | 一次冷启动搜索在 ~106s 完成 |

所以 NAPI 里给这三类单独用了 `SlowApi()`（读超时 **240s** = 实测上限的一倍余量），
执行入口是 `RunSlowLibraryRequest()`。这几个入口用户都是**显式点击后等待**，
超时定得比真实耗时更紧只会白等一场。

> 同类先例：取流与图片下载本来就用更长的超时（`setReadTimeoutSec(60)`）。

## 分层与可测性

```
ArkTS 页面（DetailPage 入口 / ItemMetadataPage）
   │  只做展示 + 表单状态，不拼 URL、不拼请求体
   ▼
NAPI（native/napi/jellyfin_napi.cpp 的 item* 一组）
   │  取参数 → 构造 LibraryRequest → RunAsync 执行（慢端点走 RunSlowLibraryRequest）
   ▼
core/api/item_metadata_api.{h,cpp}     纯函数：build*Request() + normalize*()
core/api/item_metadata_client.cpp      薄封装：getItemMetadata() / remoteSearch()
```

`item_metadata_client.cpp` 单独分出来的原因与 `library_admin_client.cpp` 相同：
`JellyfinApiClient` 的实现在 `api_client.cpp`，会连带拉进 `session.cpp` / `http_client.cpp` /
`http_tls.cpp`(mbedTLS)；把依赖客户端的那一层分出去后，主机单测只链接
`item_metadata_api.cpp` + `url_util.cpp` 即可，不需要起服务器、也不需要设备。

NAPI 接口（`jellyfin_native.d.ts`）：

```
itemMetadata(itemId)                       → { item, editor, editorError, remoteSearchType, metadataFields }
itemUpdateMetadata(itemId, itemJson)       → 整体替换
itemExternalIdInfos(itemId)
itemUpdateContentType(itemId, contentType)
itemRefreshMetadata(itemId, metadataRefreshMode, imageRefreshMode, replaceAllMetadata, replaceAllImages)
itemRemoteSearch(itemType, searchTerm, providerIdsJson, year, metadataLanguage, metadataCountryCode, itemId)
itemApplyRemoteSearch(itemId, resultJson, replaceAllImages)
```

主机单测：`native/core/tests/test_item_metadata_api.cpp`
（已在 `.github/workflows/build.yml` 的 `core-tests` 与 `scripts/force-build.ps1` 中登记），
卡三件事：

1. `GET` 的 `Fields` 覆盖全部被门控的可编辑字段（少一个 = 回传时清空一个）；
2. `POST` 请求体**原样保留**不认识的字段，只对服务端会崩/写错的两处（`ProviderIds` / `Studios`）兜底；
3. 归一化把服务端各 DTO 收敛成界面能直接画的形状。

> 顺带修了 `scripts/force-build.ps1` 的一个既有问题：它没给编译器加 `-I native/core/api`
> 与 `-I native/feature/player`，导致所有 `*_api` 与 player 相关的测试目标**根本编不过**
> （头文件以 `#include "xxx_api.h"` 直接引用）。现已补上这两条路径。

## UI 模型

`itemMetadata` 的 `data` 形状（camelCase 是界面模型，`item` 保持服务端 PascalCase 原文）：

```
{
  "item": { … },                 // 服务端条目**原文**：回填 + 整体回传都用它，不做裁剪
  "editor": {
    "parentalRatings":     [{ "name": "…", "displayName": "…", "value": "…" }],
    "countries":           [{ "name": "US", "displayName": "美国", "value": "US" }],
    "cultures":            [{ "name": "Chinese", "displayName": "中文", "value": "chi" }],
    "externalIdInfos":     [{ "name": "TheMovieDb", "displayName": "TheMovieDb", "value": "Tmdb" }],
    "contentType":         "movies",
    "contentTypeOptions":  [{ … }]
  },
  "editorError": "",             // 非空 = 下拉拿不到，字段仍可编辑（页面提示而不让整页失败）
  "remoteSearchType": "Movie",   // 空串 = 该类型不支持识别（10.8 没有 Episode）
  "metadataFields": ["Cast", "Genres", "ProductionLocations", "Studios", "Tags",
                     "Name", "Overview", "Runtime", "OfficialRating"]
}
```

- 语言的**取值**用三字母码（服务端按 `ThreeLetterISOLanguageName` 匹配，见 `docs/library-management.md`），
  显示名用 `DisplayName`；
- 国家的取值用两字母码；
- `remoteSearchType` 由 `remoteSearchTypeFor(itemType)` 得出，界面据此显示/隐藏「识别」区。

## 页面分区

| 分区 | 内容 |
| --- | --- |
| 基本信息 | 名称、原始标题、排序名、简介、发行年、首播日期 |
| 分类 | 类型（Genres）、标签（Tags）、制片公司（Studios）、拍摄地点（ProductionLocations）、宣传语（Tagline） |
| 分级与评分 | 官方分级（下拉）、自定义分级、社区评分（可空小数）、影评人评分 |
| 外部 ID | 提供方定义 × 当前取值（重名补 Key、定义外的键补漏，见上文第 8 点） |
| 语言与锁定 | 元数据语言、元数据国家、内容类型（单独端点）、锁定条目开关、锁定字段多选 |
| 识别（远程搜索） | 按名字 / 外部 ID 搜索 → 候选列表 → 应用（破坏性，有确认浮层 + 替换图片开关） |
| 刷新元数据 | 元数据刷新模式（`ValidationOnly` / `FullRefresh`）× 图片刷新模式 + 替换开关 |
| 封面与图片 | 当前图片列表（类型 / 尺寸）、从 URL 设置、删除（均有确认浮层） |

**未实现：从手机本地图片文件上传。** 与媒体库封面同一结论（见 `docs/library-management.md`）：
`POST /Items/{itemId}/Images/{imageType}` 需要二进制请求体，而现在的 `HttpClient` 只发 JSON 字符串体，
且模拟器上没有可供选择器挑选的图片源，做出来是一条无法验收的链路。

## 详情页返回后的刷新

元数据页改过数据后返回详情页，详情页要重新拉一次条目（否则标题 / 封面还是旧的）。
但**不能无条件重载**：`loadDetail()` 会把季标签重置回第 1 季，而用户从播放页返回详情页时
已选中的季不该被清掉。做法是 `ItemMetadataRefreshSignal`（`common/ItemMetadataModels.ets`）：
元数据页在**真的改过数据**时 `markChanged(itemId)`，详情页 `onPageShow` 里
`consume(itemId)`（按 itemId 精确匹配、取走即清）命中才 `reloadKeepingSeason()`
（重载后把当前选中的季恢复回去）。

## 设备验收记录（模拟器 + 真实 Jellyfin 10.8.12）

| 项目 | 观测到的证据 |
| --- | --- |
| 入口门禁 | 管理员账号下详情页出现「编辑元数据」按钮（`sys.symbol.doc_text`） |
| 页面加载 | 打开真实影片条目，各分区按服务端数据回填 |
| 小数与日期 | 社区评分显示 `6.6` / `6.7`；首播日期显示为日期（`2018-08-10` / `1978-08-12` / `1987-07-25`），未出现时间部分 |
| 数组字段往返 | 分类 / 标签 / 制片公司 / 拍摄地点 / 宣传语 改动后保存 → 重新进入本页读数一致 |
| 锁定字段 | 9 个 chip 全部渲染，勾选状态与服务端 `LockedFields` 一致 |
| 外部 ID | 重复显示名消歧生效：`TheMovieDb（Tmdb）` = 13481，`TheMovieDb（TmdbCollection）` 为空 |
| 下拉 | 元数据语言 / 元数据国家 / 内容类型 三个 Select 有值；「锁定条目」Toggle 正常 |
| 保存 | 返回「元数据已保存（服务端为整体替换，本次提交了完整条目）」；重新进入本页读数一致；随后把改动字段清空再保存，条目恢复原状 |
| 详情页联动 | 保存后 Back 回详情页，条目自动重载（`ItemMetadataRefreshSignal`） |
| 识别（按 ID） | 搜索到 `候选（1）`：「Project A 2 / The Open Movie Database · 1987 · Imdb tt0092501」 |
| 识别（按名字） | 中文名搜索无结果时显示「没有候选条目。」+「没有找到候选条目：可以换个名字或填上发行年再试」 |
| 刷新元数据 | 返回「已请求服务端刷新（异步执行，稍后重新进入本页可看到结果）」 |
| 封面与图片 | 列表如实显示 `Primary` / `Disc` / `Logo` / `Backdrop` 及尺寸；删除有确认浮层，取消可返回 |
| 本地上传提示 | 界面明确标注「本地上传暂未实现」 |

### 未通过项：应用识别结果返回 HTTP 500（服务端侧）

「应用识别结果」在设备上返回 **HTTP 500**（约 35s 后），证据指向服务端而非客户端请求形状：

1. 同一套管道、同样的管理员权限、同一个 `normalizeItemMetadataBody` 在**保存**上是成功的；
2. 路由与请求体与 `ApplySearchCriteria` 完全一致，请求体等同于官方 Web 客户端发送的
   （完整的 `RemoteSearchResult`，`ProviderIds` 在位 —— 候选条目的副标题已证明 `raw.ProviderIds`
   含 `Imdb tt0092501`）；
3. 服务端对提供方异常有 try/catch（`ProviderManager.ExecuteRemoteProviders` 与
   `ItemImageProvider.RefreshFromProvider` 都计入 `refreshResult.Failures` 而**不会** 500），
   说明抛异常的位置在更后面的管道里；
4. `MetadataService.ApplySearchResult` 对 Movie 走 `default:` 分支（不做 `ProviderIds.Clear()`）；
5. 响应体为空 / 非 JSON（界面提示退化成 `HTTP 500`），且本机拿不到服务端日志；
6. 复测期间该服务器本身处于降级状态：媒体库列表（15s）与「重试」都返回 `Read timeout`，
   因此没能完成"换一个条目再试"的对照实验。

**待办**：等服务器恢复后换个条目复测，并拿到服务端日志确认抛点。

## 已知限制

- **本地上传图片未实现**（原因见上）。
- **应用识别结果当前 500**（服务端侧，见上）。
- 服务端 `RemoteSearch` 无 Episode 端点，分集不提供「识别」入口。
- 编辑页不提供"只改一个字段"的快捷路径，保存始终提交完整条目 —— 这是整体替换语义下唯一安全的方式。
- 刷新元数据是**异步**的，页面只确认"已请求"，实际结果要稍后重新进入本页查看。
- 保存后用**系统返回键**（而非页面左上角返回箭头）退回详情页，详情页不会自动重载，仍显示旧值，
  要退出重进才刷新。原因：重载信号 `ItemMetadataRefreshSignal.markChanged()` 只在 `goBack()`
  里发出，而本页没有实现 `onBackPress()`，系统返回键绕过了它。
  （2026-09-24 在模拟器上改「名称」时发现；上表"详情页联动"那一条用的是页面自己的返回箭头。）
