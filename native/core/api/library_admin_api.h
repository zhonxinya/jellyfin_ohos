#ifndef JELLYFIN_CORE_API_LIBRARY_ADMIN_API_H
#define JELLYFIN_CORE_API_LIBRARY_ADMIN_API_H

#include "api_client.h"

#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

/**
 * 媒体库管理（Jellyfin 服务端 `LibraryStructureController` / `LibraryController` /
 * `ItemRefreshController`）的请求构造、响应归一化与执行。
 *
 * 为什么把「构造」和「执行」拆开：
 * `HttpClient` 没有可注入的传输层（`get/post/del` 直接走 socket），主机侧单测没法假装发请求；
 * 所以这里把每个端点拆成**纯函数** `build*Request()`（返回方法 + 完整路径含 query + 请求体）
 * 和一层薄薄的 `execute()`。这样 query 编码、数组/枚举拼装、请求体形状都能在主机单测里逐字断言，
 * 不需要起服务器也不需要设备 —— 参考实现见 `native/core/tests/test_library_admin_api.cpp`。
 *
 * 服务端语义（全部来自 `docs/jellyfin-10.8.12` 的源码，不是猜测）：
 * - `GET /Library/VirtualFolders` 返回 `VirtualFolderInfo[]`，字段是
 *   `Name / Locations / CollectionType / LibraryOptions / ItemId / PrimaryImageItemId /
 *    RefreshProgress / RefreshStatus`（`MediaBrowser.Model/Entities/VirtualFolderInfo.cs`）；
 * - `LibraryOptions` 用 `JsonIgnoreCondition.WhenWritingNull` 序列化（`JsonDefaults.cs`），
 *   **缺字段 = null**，而 null 在若干字段上是「继承全局配置」的语义，不能当成 false/空数组
 *   （见 `ProviderManager.cs` 的 `MetadataSavers == null`、`SubtitleDownloadLanguages == null`）；
 * - `POST /Library/VirtualFolders/LibraryOptions` 是**整体替换**（`CollectionFolder.UpdateLibraryOptions`
 *   直接 `SaveLibraryOptions`），因此必须把服务端下发的完整选项对象回传，不能只传被改的字段；
 * - `POST /Library/VirtualFolders` 的 `paths` 走 query 时是逗号分隔数组，路径里带逗号会被拆坏，
 *   所以路径统一放在请求体 `LibraryOptions.PathInfos` 里（控制器在没有 query paths 时就用它）。
 */
namespace jellyfin {
namespace api {

/** 一次媒体库管理请求的纯描述。 */
struct LibraryRequest {
    std::string method; // "GET" / "POST" / "DELETE"
    std::string path;   // 以 `/` 开头，含 query string
    nlohmann::json body = nullptr;
};

/// @name 请求构造（纯函数）
/// @{

/** `GET /Library/VirtualFolders`。 */
LibraryRequest buildVirtualFoldersRequest();

/** `GET /Libraries/AvailableOptions`：新增/编辑媒体库时可选的语言、抓取器、图片类型。 */
LibraryRequest buildAvailableOptionsRequest(const std::string &contentType, bool isNewLibrary);

/** `GET /Localization/Cultures`：首选元数据语言、字幕下载语言的下拉数据源。 */
LibraryRequest buildLocalizationCulturesRequest();

/** `GET /Localization/Countries`：元数据国家/地区的下拉数据源。 */
LibraryRequest buildLocalizationCountriesRequest();

/**
 * `POST /Library/VirtualFolders`：新增媒体库。
 * `name` 与 `collectionType` 走 query，路径走请求体（避免逗号分隔数组被路径里的逗号拆坏）。
 * 服务端要求每个路径在**服务器本机**真实存在（`LibraryManager.AddVirtualFolder` 里 `Directory.Exists`）。
 */
LibraryRequest buildAddVirtualFolderRequest(const std::string &name, const std::string &collectionType,
                                            const std::vector<std::string> &paths,
                                            const nlohmann::json &libraryOptions, bool refreshLibrary);

/** `POST /Library/VirtualFolders/Name`：重命名。 */
LibraryRequest buildRenameVirtualFolderRequest(const std::string &name, const std::string &newName,
                                               bool refreshLibrary);

/** `DELETE /Library/VirtualFolders`：删除媒体库。 */
LibraryRequest buildRemoveVirtualFolderRequest(const std::string &name, bool refreshLibrary);

/** `POST /Library/VirtualFolders/Paths`：给媒体库加一个路径。 */
LibraryRequest buildAddMediaPathRequest(const std::string &name, const std::string &path,
                                        const std::string &networkPath, bool refreshLibrary);

/** `POST /Library/VirtualFolders/Paths/Update`：改路径（含可选的网络路径映射）。 */
LibraryRequest buildUpdateMediaPathRequest(const std::string &name, const std::string &path,
                                           const std::string &networkPath);

/** `DELETE /Library/VirtualFolders/Paths`：移除路径。 */
LibraryRequest buildRemoveMediaPathRequest(const std::string &name, const std::string &path,
                                           bool refreshLibrary);

/** `POST /Library/VirtualFolders/LibraryOptions`：整体替换媒体库选项。 */
LibraryRequest buildUpdateLibraryOptionsRequest(const std::string &itemId,
                                                const nlohmann::json &libraryOptions);

/** `POST /Library/Refresh`：扫描所有媒体库。 */
LibraryRequest buildRefreshLibraryRequest();

/**
 * `GET /System/Configuration` / `POST /System/Configuration`：**服务器级**的媒体库设置
 * （媒体库显示方式、图片落盘约定、扫描并发与监控延迟）。
 *
 * 与媒体库选项一样是**整体替换**（`SystemConfigurationController.UpdateConfiguration`
 * → `ReplaceConfiguration`），所以客户端必须 GET 全量、改完再 POST 全量。
 * 实测这台服务器上 GET → 原样 POST 的往返逐字节相同（45 个字段），
 * 因此"只改一个字段"的提交不会顺带改坏别的字段。
 */
LibraryRequest buildServerConfigurationRequest();
LibraryRequest buildUpdateServerConfigurationRequest(const nlohmann::json &configuration);

/**
 * `POST /Items/{itemId}/Refresh`：只扫描单个媒体库（媒体库本身就是一个 CollectionFolder 条目）。
 * `metadataRefreshMode` / `imageRefreshMode` 取 `None` / `ValidationOnly` / `FullRefresh`。
 */
LibraryRequest buildRefreshItemRequest(const std::string &itemId, const std::string &metadataRefreshMode,
                                       const std::string &imageRefreshMode, bool replaceAllMetadata,
                                       bool replaceAllImages);

/// @name 媒体库封面（`ImageController` / `RemoteImageController`）
/// @{

/**
 * `GET /Items/{itemId}/Images`：条目已有的图片列表（`ImageInfo[]`：
 * `ImageType` / `ImageIndex` / `Width` / `Height`）。用来在界面上如实显示"当前封面尺寸"，
 * 而不是只知道"有没有"。
 */
LibraryRequest buildItemImagesRequest(const std::string &itemId);

/**
 * `POST /Items/{itemId}/RemoteImages/Download?type=&imageUrl=`：
 * 让**服务器**去把给定 URL 的图片抓下来存成封面（`ProviderManager.SaveImage`）。
 *
 * 为什么先做这一条而不是"本地上传"：本地上传要走系统图片选择器，本工程的模拟器上没有可验证的图片来源，
 * 而这条只需要一个 URL，客户端到服务端、服务端抓图、界面刷新整条链路都能在设备上验证。
 * 本地上传见 `POST /Items/{itemId}/Images/{imageType}`（二进制体），文档里记为未实现。
 */
LibraryRequest buildRemoteImageDownloadRequest(const std::string &itemId, const std::string &imageType,
                                               const std::string &imageUrl);

/**
 * `DELETE /Items/{itemId}/Images/{imageType}?imageIndex=`：删除图片。
 * `imageIndex` 为负数时不下发该参数（服务端按类型删）。
 */
LibraryRequest buildDeleteItemImageRequest(const std::string &itemId, const std::string &imageType,
                                           int imageIndex);

/// @}

/// @}
/// @name 响应归一化（纯函数）
/// @{

/**
 * 把服务端的 `LibraryOptions` 归一化成 UI 模型：
 * 补齐 C# 侧构造函数的默认值（`LibraryOptions.cs`），并把「可空数组」的 null 语义
 * 显式表达成 `<字段>Explicit = false`（表示"继承全局配置"，而不是"空列表"）。
 */
nlohmann::json normalizeLibraryOptions(const nlohmann::json &serverOptions);

/** 把单个 `VirtualFolderInfo` 归一化成 UI 模型（`locations` / `pathInfos` / `options`）。 */
nlohmann::json normalizeVirtualFolder(const nlohmann::json &serverFolder);

/** `GET /Library/VirtualFolders` 的响应 → `VirtualFolderInfo` 数组。 */
nlohmann::json normalizeVirtualFolders(const nlohmann::json &serverJson);

/**
 * 服务器级媒体库设置：补齐 UI 会用到的字段的 C# 默认值
 * （`MediaBrowser.Model/Configuration/ServerConfiguration.cs`），其余字段原样保留 ——
 * 返回的对象是**可原样回传**的（整体替换语义）。
 */
nlohmann::json normalizeServerConfiguration(const nlohmann::json &serverConfig);

/**
 * `GET /Libraries/AvailableOptions` 的响应 → UI 模型
 * （`metadataSavers` / `metadataReaders` / `subtitleFetchers` / `typeOptions`，
 * 每项统一成 `{ name, defaultEnabled }`）。
 */
nlohmann::json normalizeAvailableOptions(const nlohmann::json &serverJson);

/// @}
/// @name 执行（实现在 `library_admin_client.cpp`，因为依赖 `JellyfinApiClient`）
/// @{

/** 按 `LibraryRequest` 的方法发一次请求（`POST` 无体时发 `null`，与既有 admin 接口一致）。 */
ApiResult execute(JellyfinApiClient &client, const LibraryRequest &request);

/** `GET /Library/VirtualFolders` 并归一化。 */
ApiResult getVirtualFolders(JellyfinApiClient &client);

/**
 * 首选元数据语言 + 国家/地区：两次 GET 合成一个结果
 * `{ "cultures": [...], "countries": [...] }`，省掉 UI 上一次串行往返。
 *
 * 注意语言用的是 **`/Localization/Cultures`** 而不是 `/Localization/Languages`：
 * 后者在 Jellyfin 10.8.12 上不存在（实测 404），语言代码取 `CultureDto.ThreeLetterISOLanguageName`
 * （服务端 `LocalizationManager` 就是按三字母码匹配的，见 `GetCultures` 的消费点）。
 */
ApiResult getLocalization(JellyfinApiClient &client);

/// @}

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_LIBRARY_ADMIN_API_H */
