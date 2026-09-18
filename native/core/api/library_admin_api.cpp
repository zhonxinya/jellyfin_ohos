#include "library_admin_api.h"

#include "url_util.h"

namespace jellyfin {
namespace api {
namespace {

std::string BoolLiteral(bool value)
{
    return value ? "true" : "false";
}

/**
 * 追加一个 query 参数。
 * 所有调用点都从 `"<route>?"` 开始拼，所以分隔符由"路径当前是否以 `?` 结尾"决定：
 * 是则第一个参数不加分隔符，否则加 `&`。把这条规则收在函数里，
 * 避免每个调用点各自判断"我是第几个参数"——这正是单测最容易抓到的拼串错误。
 */
void AppendParam(std::string &path, const char *name, const std::string &value)
{
    if (path.empty() || path.back() != '?') {
        path += '&';
    }
    path += name;
    path += '=';
    path += value;
}

/** 追加 `&name=<percent-encoded value>`。 */
void AppendEncoded(std::string &path, const char *name, const std::string &value)
{
    AppendParam(path, name, EncodeQueryComponent(value));
}

void AppendBool(std::string &path, const char *name, bool value)
{
    AppendParam(path, name, BoolLiteral(value));
}

nlohmann::json JsonArrayOr(const nlohmann::json &src, const char *key)
{
    if (src.is_object() && src.contains(key) && src[key].is_array()) {
        return src[key];
    }
    return nlohmann::json::array();
}

std::string JsonStringOr(const nlohmann::json &src, const char *key)
{
    if (src.is_object() && src.contains(key) && src[key].is_string()) {
        return src[key].get<std::string>();
    }
    return {};
}

nlohmann::json NormalizeStringArray(const nlohmann::json &src)
{
    nlohmann::json out = nlohmann::json::array();
    if (!src.is_array()) {
        return out;
    }
    for (const auto &item : src) {
        if (item.is_string()) {
            out.push_back(item);
        }
    }
    return out;
}

/**
 * `LibraryOptions` 里**不可为 null** 的字段及其 C# 构造函数默认值，逐项抄自
 * `MediaBrowser.Model/Configuration/LibraryOptions.cs`（Jellyfin 10.8.12）。
 *
 * 只列不可空字段：服务端用 `JsonIgnoreCondition.WhenWritingNull` 序列化，可空字段
 * 一旦被这里补成默认值，回传时就会把"继承全局配置"变成"显式空列表"，语义被改掉。
 */
nlohmann::json NonNullableLibraryOptionDefaults()
{
    return nlohmann::json::object({
        {"EnablePhotos", true},
        {"EnableRealtimeMonitor", true},
        {"EnableChapterImageExtraction", false},
        {"ExtractChapterImagesDuringLibraryScan", false},
        {"PathInfos", nlohmann::json::array()},
        {"SaveLocalMetadata", false},
        {"EnableAutomaticSeriesGrouping", true},
        {"EnableEmbeddedTitles", false},
        {"EnableEmbeddedEpisodeInfos", false},
        {"AutomaticRefreshIntervalDays", 0},
        {"SeasonZeroDisplayName", "Specials"},
        {"DisabledLocalMetadataReaders", nlohmann::json::array()},
        {"DisabledSubtitleFetchers", nlohmann::json::array()},
        {"SubtitleFetcherOrder", nlohmann::json::array()},
        {"SkipSubtitlesIfEmbeddedSubtitlesPresent", false},
        {"SkipSubtitlesIfAudioTrackMatches", true},
        {"RequirePerfectSubtitleMatch", true},
        {"SaveSubtitlesWithMedia", true},
        {"AutomaticallyAddToCollection", false},
        {"AllowEmbeddedSubtitles", "AllowAll"},
        {"TypeOptions", nlohmann::json::array()},
    });
}

/** 可空字符串字段：服务端省略时补 `""`（服务端各处用 `string.IsNullOrEmpty` 判断，等价于 null）。 */
nlohmann::json NullableStringOptionDefaults()
{
    return nlohmann::json::object({
        {"PreferredMetadataLanguage", ""},
        {"MetadataCountryCode", ""},
    });
}

/**
 * 可空**数组**字段：只在服务端确实下发时才出现。
 * `ProviderManager` 用 `libraryOptions.MetadataSavers == null` / `SubtitleDownloadLanguages == null`
 * 判定"沿用全局配置"，所以这里刻意**不补空数组**，让 UI 能区分「未显式配置」与「显式空」。
 */
const char *const kNullableArrayOptions[] = {
    "MetadataSavers",
    "LocalMetadataReaderOrder",
    "SubtitleDownloadLanguages",
};

/** `MediaPathInfo` 的 UI 视图（camelCase），只用于展示/编辑，不参与回传。 */
nlohmann::json NormalizePathInfos(const nlohmann::json &src)
{
    nlohmann::json out = nlohmann::json::array();
    if (!src.is_array()) {
        return out;
    }
    for (const auto &item : src) {
        out.push_back(nlohmann::json::object({
            {"path", JsonStringOr(item, "Path")},
            {"networkPath", JsonStringOr(item, "NetworkPath")},
        }));
    }
    return out;
}

/** `ImageOption`：历史字段名是 `Type`，序列化名是 `ImageType`，两种都接受。 */
nlohmann::json NormalizeImageOption(const nlohmann::json &src)
{
    if (!src.is_object()) {
        return nlohmann::json::object({{"imageType", ""}, {"limit", 0}, {"minWidth", 0}});
    }
    std::string type = JsonStringOr(src, "ImageType");
    if (type.empty()) {
        type = JsonStringOr(src, "Type");
    }
    int limit = 0;
    int minWidth = 0;
    if (src.contains("Limit") && src["Limit"].is_number()) {
        limit = src["Limit"].get<int>();
    }
    if (src.contains("MinWidth") && src["MinWidth"].is_number()) {
        minWidth = src["MinWidth"].get<int>();
    }
    return nlohmann::json::object({{"imageType", type}, {"limit", limit}, {"minWidth", minWidth}});
}

nlohmann::json NormalizeImageOptions(const nlohmann::json &src)
{
    nlohmann::json out = nlohmann::json::array();
    if (!src.is_array()) {
        return out;
    }
    for (const auto &item : src) {
        out.push_back(NormalizeImageOption(item));
    }
    return out;
}

/** `LibraryOptionInfoDto` 的统一形状：`{ name, defaultEnabled }`。 */
nlohmann::json NormalizeOptionInfoList(const nlohmann::json &src)
{
    nlohmann::json out = nlohmann::json::array();
    if (!src.is_array()) {
        return out;
    }
    for (const auto &item : src) {
        bool enabled = false;
        if (item.is_object() && item.contains("DefaultEnabled") && item["DefaultEnabled"].is_boolean()) {
            enabled = item["DefaultEnabled"].get<bool>();
        }
        out.push_back(nlohmann::json::object({
            {"name", JsonStringOr(item, "Name")},
            {"defaultEnabled", enabled},
        }));
    }
    return out;
}

} // namespace

// ── 请求构造 ────────────────────────────────────────────────────────────────

LibraryRequest buildVirtualFoldersRequest()
{
    return LibraryRequest{"GET", "/Library/VirtualFolders", nullptr};
}

LibraryRequest buildAvailableOptionsRequest(const std::string &contentType, bool isNewLibrary)
{
    std::string path = "/Libraries/AvailableOptions?";
    if (!contentType.empty()) {
        AppendEncoded(path, "libraryContentType", contentType);
    }
    AppendBool(path, "isNewLibrary", isNewLibrary);
    return LibraryRequest{"GET", path, nullptr};
}

LibraryRequest buildLocalizationCulturesRequest()
{
    // 10.8.12 的 LocalizationController 只有 Cultures / Countries / ParentalRatings / Options，
    // 没有 Languages（实测请求 /Localization/Languages 返回 404）
    return LibraryRequest{"GET", "/Localization/Cultures", nullptr};
}

LibraryRequest buildLocalizationCountriesRequest()
{
    return LibraryRequest{"GET", "/Localization/Countries", nullptr};
}

LibraryRequest buildAddVirtualFolderRequest(const std::string &name, const std::string &collectionType,
                                            const std::vector<std::string> &paths,
                                            const nlohmann::json &libraryOptions, bool refreshLibrary)
{
    std::string path = "/Library/VirtualFolders?";
    AppendEncoded(path, "name", name);
    if (!collectionType.empty()) {
        AppendEncoded(path, "collectionType", collectionType);
    }
    AppendBool(path, "refreshLibrary", refreshLibrary);

    nlohmann::json options = libraryOptions.is_object() ? libraryOptions : nlohmann::json::object();
    if (!paths.empty()) {
        nlohmann::json pathInfos = nlohmann::json::array();
        for (const std::string &p : paths) {
            pathInfos.push_back(nlohmann::json::object({{"Path", p}}));
        }
        options["PathInfos"] = pathInfos;
    }
    return LibraryRequest{"POST", path,
                          nlohmann::json::object({{"LibraryOptions", options}})};
}

LibraryRequest buildRenameVirtualFolderRequest(const std::string &name, const std::string &newName,
                                               bool refreshLibrary)
{
    std::string path = "/Library/VirtualFolders/Name?";
    AppendEncoded(path, "name", name);
    AppendEncoded(path, "newName", newName);
    AppendBool(path, "refreshLibrary", refreshLibrary);
    return LibraryRequest{"POST", path, nullptr};
}

LibraryRequest buildRemoveVirtualFolderRequest(const std::string &name, bool refreshLibrary)
{
    std::string path = "/Library/VirtualFolders?";
    AppendEncoded(path, "name", name);
    AppendBool(path, "refreshLibrary", refreshLibrary);
    return LibraryRequest{"DELETE", path, nullptr};
}

LibraryRequest buildAddMediaPathRequest(const std::string &name, const std::string &path,
                                        const std::string &networkPath, bool refreshLibrary)
{
    std::string route = "/Library/VirtualFolders/Paths?";
    AppendBool(route, "refreshLibrary", refreshLibrary);

    nlohmann::json pathInfo = nlohmann::json::object({{"Path", path}, {"NetworkPath", nullptr}});
    if (!networkPath.empty()) {
        pathInfo["NetworkPath"] = networkPath;
    }
    return LibraryRequest{"POST", route,
                          nlohmann::json::object({{"Name", name},
                                                  {"Path", path},
                                                  {"PathInfo", pathInfo}})};
}

LibraryRequest buildUpdateMediaPathRequest(const std::string &name, const std::string &path,
                                           const std::string &networkPath)
{
    nlohmann::json pathInfo = nlohmann::json::object({{"Path", path}, {"NetworkPath", nullptr}});
    if (!networkPath.empty()) {
        pathInfo["NetworkPath"] = networkPath;
    }
    return LibraryRequest{"POST", "/Library/VirtualFolders/Paths/Update",
                          nlohmann::json::object({{"Name", name}, {"PathInfo", pathInfo}})};
}

LibraryRequest buildRemoveMediaPathRequest(const std::string &name, const std::string &path,
                                           bool refreshLibrary)
{
    std::string route = "/Library/VirtualFolders/Paths?";
    AppendEncoded(route, "name", name);
    AppendEncoded(route, "path", path);
    AppendBool(route, "refreshLibrary", refreshLibrary);
    return LibraryRequest{"DELETE", route, nullptr};
}

LibraryRequest buildUpdateLibraryOptionsRequest(const std::string &itemId,
                                                const nlohmann::json &libraryOptions)
{
    nlohmann::json options = libraryOptions.is_object() ? libraryOptions : nlohmann::json::object();
    return LibraryRequest{"POST", "/Library/VirtualFolders/LibraryOptions",
                          nlohmann::json::object({{"Id", itemId}, {"LibraryOptions", options}})};
}

LibraryRequest buildRefreshLibraryRequest()
{
    return LibraryRequest{"POST", "/Library/Refresh", nullptr};
}

LibraryRequest buildServerConfigurationRequest()
{
    return LibraryRequest{"GET", "/System/Configuration", nullptr};
}

LibraryRequest buildUpdateServerConfigurationRequest(const nlohmann::json &configuration)
{
    // 整体替换：必须回传完整配置对象（缺字段会被服务端按 C# 默认值重置）
    return LibraryRequest{"POST", "/System/Configuration",
                          configuration.is_object() ? configuration : nlohmann::json::object()};
}

LibraryRequest buildRefreshItemRequest(const std::string &itemId, const std::string &metadataRefreshMode,
                                       const std::string &imageRefreshMode, bool replaceAllMetadata,
                                       bool replaceAllImages)
{
    std::string path = "/Items/" + EncodeQueryComponent(itemId) + "/Refresh?";
    AppendParam(path, "metadataRefreshMode",
                metadataRefreshMode.empty() ? std::string("None") : metadataRefreshMode);
    AppendParam(path, "imageRefreshMode",
                imageRefreshMode.empty() ? std::string("None") : imageRefreshMode);
    AppendBool(path, "replaceAllMetadata", replaceAllMetadata);
    AppendBool(path, "replaceAllImages", replaceAllImages);
    return LibraryRequest{"POST", path, nullptr};
}

// ── 响应归一化 ──────────────────────────────────────────────────────────────

nlohmann::json normalizeServerConfiguration(const nlohmann::json &serverConfig)
{
    // 只补"媒体库"这一组设置的默认值，其余字段原样保留（回传时不能丢）：
    // 默认值逐项抄自 MediaBrowser.Model/Configuration/ServerConfiguration.cs（10.8.12）
    const nlohmann::json defaults = nlohmann::json::object({
        {"EnableFolderView", false},
        {"EnableGroupingIntoCollections", false},
        {"DisplaySpecialsWithinSeasons", true},
        {"SaveMetadataHidden", false},
        {"ImageSavingConvention", "Legacy"},
        {"LibraryMonitorDelay", 60},
        {"LibraryScanFanoutConcurrency", 0},
        {"LibraryMetadataRefreshConcurrency", 0},
    });

    nlohmann::json out = serverConfig.is_object() ? serverConfig : nlohmann::json::object();
    for (auto it = defaults.begin(); it != defaults.end(); ++it) {
        if (!out.contains(it.key()) || out[it.key()].is_null()) {
            out[it.key()] = it.value();
        }
    }
    return out;
}

nlohmann::json normalizeLibraryOptions(const nlohmann::json &serverOptions)
{
    const nlohmann::json src =
        serverOptions.is_object() ? serverOptions : nlohmann::json::object();
    // 以服务端对象为底：未知字段原样保留，向前兼容新版本服务端新增的选项。
    nlohmann::json out = src;

    const nlohmann::json defaults = NonNullableLibraryOptionDefaults();
    for (auto it = defaults.begin(); it != defaults.end(); ++it) {
        if (!out.contains(it.key()) || out[it.key()].is_null()) {
            out[it.key()] = it.value();
        }
    }
    const nlohmann::json nullableStrings = NullableStringOptionDefaults();
    for (auto it = nullableStrings.begin(); it != nullableStrings.end(); ++it) {
        if (!out.contains(it.key()) || !out[it.key()].is_string()) {
            out[it.key()] = it.value();
        }
    }

    for (const char *key : kNullableArrayOptions) {
        if (out.contains(key) && !out[key].is_null()) {
            out[key] = NormalizeStringArray(out[key]);
        }
    }
    out["DisabledLocalMetadataReaders"] = NormalizeStringArray(out["DisabledLocalMetadataReaders"]);
    out["DisabledSubtitleFetchers"] = NormalizeStringArray(out["DisabledSubtitleFetchers"]);
    out["SubtitleFetcherOrder"] = NormalizeStringArray(out["SubtitleFetcherOrder"]);

    // TypeOptions 的数组字段补空数组，避免 UI 侧到处判空
    nlohmann::json typeOptions = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(out, "TypeOptions")) {
        nlohmann::json entry = item.is_object() ? item : nlohmann::json::object();
        for (const char *key : {"MetadataFetchers", "MetadataFetcherOrder", "ImageFetchers",
                                "ImageFetcherOrder"}) {
            if (!entry.contains(key) || !entry[key].is_array()) {
                entry[key] = nlohmann::json::array();
            }
        }
        typeOptions.push_back(entry);
    }
    out["TypeOptions"] = typeOptions;
    return out;
}

nlohmann::json normalizeVirtualFolder(const nlohmann::json &serverFolder)
{
    const nlohmann::json src =
        serverFolder.is_object() ? serverFolder : nlohmann::json::object();

    const std::string primaryImageItemId = JsonStringOr(src, "PrimaryImageItemId");
    const nlohmann::json options = normalizeLibraryOptions(
        src.contains("LibraryOptions") ? src["LibraryOptions"] : nlohmann::json(nullptr));

    nlohmann::json out = nlohmann::json::object({
        {"name", JsonStringOr(src, "Name")},
        {"itemId", JsonStringOr(src, "ItemId")},
        // 服务端用 JsonLowerCaseConverter 序列化这个枚举，UI 不必再兼容大小写
        {"collectionType", JsonStringOr(src, "CollectionType")},
        {"locations", NormalizeStringArray(JsonArrayOr(src, "Locations"))},
        {"refreshStatus", JsonStringOr(src, "RefreshStatus")},
        {"primaryImageItemId", primaryImageItemId},
        {"hasPrimaryImage", !primaryImageItemId.empty()},
        // 路径的 UI 视图（含网络路径映射），来自 LibraryOptions.PathInfos，不参与回传
        {"pathInfos", NormalizePathInfos(JsonArrayOr(options, "PathInfos"))},
        // 原样可回传的完整选项对象（PascalCase，键名即服务端字段名）
        {"options", options},
    });

    if (src.contains("RefreshProgress") && src["RefreshProgress"].is_number()) {
        out["refreshing"] = true;
        out["refreshProgress"] = src["RefreshProgress"].get<double>();
    } else {
        out["refreshing"] = false;
        out["refreshProgress"] = nullptr;
    }

    // 兼容分支：个别服务端/旧版本只把路径放在 LibraryOptions.PathInfos 里，Locations 为空
    if (out["locations"].empty() && !out["pathInfos"].empty()) {
        nlohmann::json locations = nlohmann::json::array();
        for (const auto &info : out["pathInfos"]) {
            const std::string value = JsonStringOr(info, "path");
            if (!value.empty()) {
                locations.push_back(value);
            }
        }
        out["locations"] = locations;
    }
    return out;
}

nlohmann::json normalizeVirtualFolders(const nlohmann::json &serverJson)
{
    nlohmann::json out = nlohmann::json::array();
    if (serverJson.is_array()) {
        for (const auto &folder : serverJson) {
            out.push_back(normalizeVirtualFolder(folder));
        }
        return out;
    }
    if (serverJson.is_object() && serverJson.contains("Items") && serverJson["Items"].is_array()) {
        for (const auto &folder : serverJson["Items"]) {
            out.push_back(normalizeVirtualFolder(folder));
        }
    }
    return out;
}

nlohmann::json normalizeAvailableOptions(const nlohmann::json &serverJson)
{
    const nlohmann::json src = serverJson.is_object() ? serverJson : nlohmann::json::object();

    nlohmann::json typeOptions = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "TypeOptions")) {
        typeOptions.push_back(nlohmann::json::object({
            {"type", JsonStringOr(item, "Type")},
            {"metadataFetchers", NormalizeOptionInfoList(JsonArrayOr(item, "MetadataFetchers"))},
            {"imageFetchers", NormalizeOptionInfoList(JsonArrayOr(item, "ImageFetchers"))},
            {"supportedImageTypes", NormalizeStringArray(JsonArrayOr(item, "SupportedImageTypes"))},
            {"defaultImageOptions", NormalizeImageOptions(JsonArrayOr(item, "DefaultImageOptions"))},
        }));
    }

    return nlohmann::json::object({
        {"metadataSavers", NormalizeOptionInfoList(JsonArrayOr(src, "MetadataSavers"))},
        {"metadataReaders", NormalizeOptionInfoList(JsonArrayOr(src, "MetadataReaders"))},
        {"subtitleFetchers", NormalizeOptionInfoList(JsonArrayOr(src, "SubtitleFetchers"))},
        {"typeOptions", typeOptions},
    });
}

} // namespace api
} // namespace jellyfin
