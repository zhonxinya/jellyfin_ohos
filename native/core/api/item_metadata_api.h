#ifndef JELLYFIN_CORE_API_ITEM_METADATA_API_H
#define JELLYFIN_CORE_API_ITEM_METADATA_API_H

#include "api_client.h"
#include "library_admin_api.h"

#include <string>

#include <nlohmann/json.hpp>

/**
 * 条目（影视）元数据管理 —— 服务端 `ItemUpdateController` / `ItemLookupController` /
 * `ItemRefreshController`（源码见 `docs/jellyfin-10.8.12`）。
 *
 * 与 `library_admin_api` 同一套分层：每个端点拆成**纯函数** `build*Request()` +
 * 归一化函数，依赖 HTTP 的执行层单独放在 `item_metadata_client.cpp`，
 * 这样 query 编码、请求体形状、"整体替换"的字段完整性都能在主机单测里逐字断言
 * （见 `native/core/tests/test_item_metadata_api.cpp`）。
 *
 * ## 权限
 * 这三个控制器在服务端都是 `[Authorize(Policy = Policies.RequiresElevation)]`
 * —— **只有管理员**能读元数据编辑器、改字段、识别、刷新条目。NAPI 侧用 `RequireAdmin()` 兜底，
 * 界面侧再用 `AppViewModel.isAdmin` 决定是否显示入口。
 *
 * ## 服务端语义（都不是猜测，逐条来自源码）
 * - `POST /Items/{itemId}` 是**整体替换**：`ItemUpdateController.UpdateItem` 把请求 DTO 的字段
 *   逐个赋给条目，**没带的字段会被写空**（`item.Genres = request.Genres`），
 *   其中 `IsLocked = request.LockData ?? false` —— 少了 `LockData` 就会把条目的锁定状态**解锁**；
 * - `request.ProviderIds.ToList()` 没有 null 保护，`ProviderIds` 缺失会直接 500
 *   （`BaseItemDto.ProviderIds` 没有初始化器）——所以请求体里它**必须**是对象；
 * - `GET /Users/{userId}/Items/{itemId}` 的字段是**按 `Fields` 门控**的：
 *   `ProviderIds` / `Genres` / `Tags` / `Studios` / `Overview` / `Taglines` /
 *   `ProductionLocations` / `SortName` / `CustomRating` / `OriginalTitle` / `DateCreated`
 *   以及 `Settings`（它同时管 `PreferredMetadataLanguage`、`PreferredMetadataCountryCode`、
 *   `LockedFields`、`CriticRating`）**不请求就不返回**；不返回 + 整体替换 = 静默清空。
 *   所以本模块的 `Fields` 必须覆盖全部可编辑字段（见 `kItemMetadataEditFields`）；
 * - `POST /Items/RemoteSearch/{ItemType}` 的 `ItemType` 只有 Movie / Trailer / MusicVideo /
 *   Series / BoxSet / MusicArtist / MusicAlbum / Person / Book —— **没有 Episode**
 *   （分集元数据跟着剧走，`remoteSearchTypeFor` 对不支持的类型返回空串）；
 * - `POST /Items/RemoteSearch/Apply/{itemId}` 会 `FullRefresh + ReplaceAllMetadata +
 *   RemoveOldMetadata`，是**破坏性**的"重新识别"：用户改过的字段会被覆盖。
 */
namespace jellyfin {
namespace api {

/**
 * 元数据编辑需要的条目字段（`Fields=` 的值）。
 *
 * 覆盖 `DtoService` 里**被 `ItemFields` 门控**的可编辑字段；少一个就可能在整体替换时被清空
 * （见头文件顶部的说明）。`People` 不在门控里，但一并取回来，回传时原样带回去更安全。
 */
extern const char *const kItemMetadataEditFields;

/// @name 请求构造（纯函数）
/// @{

/**
 * `GET /Users/{userId}/Items/{itemId}?Fields=<kItemMetadataEditFields>`：
 * 条目**完整** DTO —— 表单回填与整体回传都用它（不要另拼一个"只含被改字段"的请求体）。
 */
LibraryRequest buildItemMetadataRequest(const std::string &userId, const std::string &itemId);

/**
 * `GET /Items/{itemId}/MetadataEditor`：编辑器的下拉数据源
 * （分级 / 国家 / 语言 / 外部 ID 定义 / 内容类型选项）。
 */
LibraryRequest buildMetadataEditorRequest(const std::string &itemId);

/** `GET /Items/{itemId}/ExternalIdInfos`：该条目可用的外部 ID 提供方（IMDB/TMDb/TVDB…）。 */
LibraryRequest buildExternalIdInfosRequest(const std::string &itemId);

/**
 * `POST /Items/{itemId}`：整体替换条目元数据。
 *
 * `itemDto` 必须是**完整条目对象**（`buildItemMetadataRequest` 的响应原文 + 用户改动）；
 * 只传被改的字段会清空其它字段（见头文件顶部）。请求体会经 `normalizeItemMetadataBody`
 * 兜底（`ProviderIds` 必须是对象、`Studios` 必须是 `{Name}` 对象数组）。
 */
LibraryRequest buildUpdateItemRequest(const std::string &itemId, const nlohmann::json &itemDto);

/**
 * `POST /Items/{itemId}/ContentType?contentType=<值>`：设置 / 清除条目的内容类型覆盖。
 *
 * 为什么单独一个端点：`ItemUpdateController.UpdateItem` **不处理** `ContentType`
 * —— 它由 `UpdateItemContentType` 按"条目所在路径 → 内容类型"写进**服务器配置**
 * （`Configuration.ContentTypes`），所以没法跟其它字段一起整体替换。
 * 空串 = 清除覆盖（回到从媒体库继承）。
 */
LibraryRequest buildUpdateContentTypeRequest(const std::string &itemId,
                                            const std::string &contentType);

/**
 * 一次远程搜索的条件（`RemoteSearchQuery<T>` + 它包着的 `ItemLookupInfo`）。
 *
 * 字段与 `MediaBrowser.Controller/Providers/ItemLookupInfo.cs` 一一对应，
 * 命名刻意保持"能看出对应哪个字段"，便于对照服务端排查。
 */
struct RemoteSearchQuery {
    /** `RemoteSearch` 端点类型（Movie / Series / BoxSet…）；见 `remoteSearchTypeFor`。 */
    std::string itemType;
    /** 归属条目：服务端用它继承该条目的元数据语言等设置（重新识别时就是条目自己）。 */
    std::string itemId;
    std::string searchTerm;
    /**
     * 已知外部 ID（IMDB/TMDb/TVDB…）。
     *
     * 非空时按 ID 精确查，比按名字查准得多 —— 重新识别（改错 ID 后纠正）就该用它。
     */
    nlohmann::json providerIds = nullptr;
    /** 发行年；`0` 表示不限（服务端 `ItemLookupInfo.Year` 是可空 int）。 */
    int year = 0;
    /** 元数据语言（三字母码）与地区码，取自条目本身，让搜索在正确的语言下进行。 */
    std::string metadataLanguage;
    std::string metadataCountryCode;
    /**
     * 专辑艺术家名（`AlbumInfo.AlbumArtists`）——**专辑搜索必须带**。
     *
     * `MusicBrainzAlbumProvider.GetSearchResults` 走的是
     * `release/?query="{名称}" AND artist:"{GetAlbumArtist()}"`，而 `GetAlbumArtist()`
     * 只认 `AlbumInfo.AlbumArtists`（见 `MediaBrowser.Providers/Music/AlbumInfoExtensions.cs`）。
     * 不带它查询就退化成 `artist:""`，等于搜不出东西 —— 这是音乐「识别」原本失效的原因。
     */
    nlohmann::json albumArtists = nlohmann::json::array();
    /**
     * 专辑艺术家的外部 ID（`AlbumInfo.ArtistProviderIds`）。
     *
     * 有 `MusicBrainzArtist` 时服务端改用 `arid:` 精确查，比按名字查准得多。
     */
    nlohmann::json artistProviderIds = nullptr;
};

/**
 * `POST /Items/RemoteSearch/{itemType}`：让服务端去外部提供方搜候选条目。
 *
 * `IsAutomated` 显式写 `false`：这是**手动**搜索，服务端 `ItemLookupInfo` 的构造默认是 `true`，
 * 而 `ItemRefreshController` 的手动刷新同样写 `false`（见源码）。
 */
LibraryRequest buildRemoteSearchRequest(const RemoteSearchQuery &query);

/**
 * `POST /Items/RemoteSearch/Apply/{itemId}`：把某个候选结果应用到条目上。
 *
 * `searchResult` 用 `normalizeRemoteSearchResults` 给出的项原文（服务端要的是
 * `RemoteSearchResult`，`ProviderIds` 是它唯一的"身份"）。
 */
LibraryRequest buildApplyRemoteSearchRequest(const std::string &itemId,
                                             const nlohmann::json &searchResult,
                                             bool replaceAllImages);

/// @}

/// @name 归一化（纯函数）
/// @{

/**
 * `GET /Items/{itemId}/MetadataEditor` 的响应 → UI 模型：
 * `{ parentalRatings, countries, cultures, externalIdInfos, contentType, contentTypeOptions }`。
 *
 * 每项都收敛成 `{ name, displayName, value }` 这类"界面直接能画"的形状，
 * 页面不必知道服务端 `CountryInfo` / `CultureDto` 的字段名。
 * 语言的**取值**用三字母码（服务端按 `ThreeLetterISOLanguageName` 匹配，见
 * `docs/library-management.md`），显示名用 `DisplayName`。
 */
nlohmann::json normalizeMetadataEditorInfo(const nlohmann::json &serverJson);

/** `POST /Items/RemoteSearch/{itemType}` 的响应 → UI 模型（`RemoteSearchResult[]`）。 */
nlohmann::json normalizeRemoteSearchResults(const nlohmann::json &serverJson);

/**
 * 整体替换请求体的兜底，只做服务端会直接崩/写错的事：
 * - `ProviderIds` 必须是对象（服务端 `request.ProviderIds.ToList()` 无 null 保护）；
 * - `Studios` 必须是 `[{ "Name": "..." }]`（服务端取 `.Name`；界面把它当字符串列表编辑，
 *   所以这里要能接受 `["华纳"]` 这种写法）；
 * - `AlbumArtists` / `ArtistItems` 必须是 `[{ "Name": "..." }]`（服务端同样取 `.Name`，
 *   且 DTO 类型是 `NameGuidPair[]` —— 收到 `["周杰伦"]` 这种字符串数组会反序列化失败）。
 *
 * 其余字段原样保留 —— 包括本模块不认识的字段，这是"整体替换"安全的前提。
 */
nlohmann::json normalizeItemMetadataBody(const nlohmann::json &body);

/** 条目类型 → `RemoteSearch` 端点类型；服务端没有该类型的端点时返回空串。 */
std::string remoteSearchTypeFor(const std::string &itemType);

/** 服务端 `MetadataField` 枚举的全部取值（界面的「锁定字段」多选项）。 */
const nlohmann::json &metadataFieldNames();

/// @}

/// @name 执行（实现在 `item_metadata_client.cpp`，因为依赖 `JellyfinApiClient`）
/// @{

/**
 * 条目 + 编辑器信息：两次 GET 合成一个结果，省掉界面上一次串行往返
 * （编辑器信息只是下拉数据源，拿不到时不应让整页失败）。
 *
 * 结果形状：
 * - `item`：条目**完整** DTO（表单回填 + 整体回传都用它）；
 * - `editor`：归一化后的下拉数据源；失败时是空对象；
 * - `editorError`：编辑器信息读取失败的说明（空串 = 成功）；
 * - `remoteSearchType`：可用的 `RemoteSearch` 端点类型，空串 = 该类型不支持识别（见 `remoteSearchTypeFor`）；
 * - `metadataFields`：可锁定字段的枚举取值（见 `metadataFieldNames`）。
 */
ApiResult getItemMetadata(JellyfinApiClient &client, const std::string &userId,
                          const std::string &itemId);

/** 远程搜索并归一化（`POST /Items/RemoteSearch/{itemType}`）。 */
ApiResult remoteSearch(JellyfinApiClient &client, const RemoteSearchQuery &query);

/// @}

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_ITEM_METADATA_API_H */
