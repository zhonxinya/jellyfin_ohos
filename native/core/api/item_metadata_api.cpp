#include "item_metadata_api.h"

#include "url_util.h"

#include <algorithm>

namespace jellyfin {
namespace api {
namespace {

void AppendParam(std::string &path, const char *name, const std::string &value)
{
    if (path.empty() || path.back() != '?') {
        path += '&';
    }
    path += name;
    path += '=';
    path += value;
}

std::string JsonStringOr(const nlohmann::json &src, const char *key)
{
    if (src.is_object() && src.contains(key) && src[key].is_string()) {
        return src[key].get<std::string>();
    }
    return {};
}

nlohmann::json JsonArrayOr(const nlohmann::json &src, const char *key)
{
    if (src.is_object() && src.contains(key) && src[key].is_array()) {
        return src[key];
    }
    return nlohmann::json::array();
}

/** 只保留非空字符串，并去掉首尾空白 —— 服务端的字符串数组字段不接受空串（会建出空标签）。 */
std::string Trimmed(const std::string &value)
{
    const std::size_t begin = value.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return {};
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(begin, end - begin + 1);
}

nlohmann::json NormalizeStringArray(const nlohmann::json &src)
{
    nlohmann::json out = nlohmann::json::array();
    if (!src.is_array()) {
        return out;
    }
    for (const auto &item : src) {
        if (!item.is_string()) {
            continue;
        }
        const std::string value = Trimmed(item.get<std::string>());
        if (!value.empty()) {
            out.push_back(value);
        }
    }
    return out;
}

/**
 * 服务端的 `CountryInfo` / `CultureDto` / `ParentalRating` / `ExternalIdInfo` / `NameValuePair`
 * 都收敛成 `{ name, displayName, value }`：页面只认这三个键，不必知道各 DTO 的字段名。
 */
nlohmann::json OptionEntry(const std::string &name, const std::string &displayName,
                           const std::string &value)
{
    return nlohmann::json::object({
        {"name", name},
        {"displayName", displayName.empty() ? name : displayName},
        {"value", value},
    });
}

} // namespace

const char *const kItemMetadataEditFields =
    // 被 ItemFields 门控、少一个就会被整体替换清空的字段
    "ProviderIds,Genres,Tags,Studios,Overview,Taglines,ProductionLocations,Settings,"
    "DateCreated,SortName,CustomRating,OriginalTitle,"
    // 未被门控（总是返回），但一并取回，整体回传时更完整
    "People,IndexNumber,ParentIndexNumber,CommunityRating,OfficialRating,ProductionYear,"
    "PremiereDate,RunTimeTicks,DisplayOrder,AspectRatio,EndDate,AirDays,AirTime,Status,"
    "AlbumArtists,ArtistItems,Album,Video3DFormat,Path,MediaSources";

LibraryRequest buildItemMetadataRequest(const std::string &userId, const std::string &itemId)
{
    std::string path = "/Users/" + EncodeQueryComponent(userId) + "/Items/" +
                       EncodeQueryComponent(itemId) + "?";
    // 字段清单是编译期常量（只有字母和逗号），不编码也安全；这里逐字写出便于对照服务端枚举名
    AppendParam(path, "Fields", kItemMetadataEditFields);
    return LibraryRequest{"GET", path, nullptr};
}

LibraryRequest buildMetadataEditorRequest(const std::string &itemId)
{
    return LibraryRequest{"GET",
                          "/Items/" + EncodeQueryComponent(itemId) + "/MetadataEditor", nullptr};
}

LibraryRequest buildExternalIdInfosRequest(const std::string &itemId)
{
    return LibraryRequest{"GET",
                          "/Items/" + EncodeQueryComponent(itemId) + "/ExternalIdInfos", nullptr};
}

LibraryRequest buildUpdateItemRequest(const std::string &itemId, const nlohmann::json &itemDto)
{
    return LibraryRequest{"POST", "/Items/" + EncodeQueryComponent(itemId),
                          normalizeItemMetadataBody(itemDto)};
}

LibraryRequest buildUpdateContentTypeRequest(const std::string &itemId,
                                            const std::string &contentType)
{
    std::string path = "/Items/" + EncodeQueryComponent(itemId) + "/ContentType?";
    AppendParam(path, "contentType", EncodeQueryComponent(contentType));
    return LibraryRequest{"POST", path, nullptr};
}

LibraryRequest buildRemoteSearchRequest(const RemoteSearchQuery &query)
{
    nlohmann::json searchInfo = nlohmann::json::object({
        {"Name", query.searchTerm},
        {"IsAutomated", false},
        {"ProviderIds", query.providerIds.is_object() ? query.providerIds
                                                     : nlohmann::json::object()},
    });
    if (query.year > 0) {
        searchInfo["Year"] = query.year;
    }
    if (!query.metadataLanguage.empty()) {
        searchInfo["MetadataLanguage"] = query.metadataLanguage;
    }
    if (!query.metadataCountryCode.empty()) {
        searchInfo["MetadataCountryCode"] = query.metadataCountryCode;
    }

    nlohmann::json body = nlohmann::json::object({
        {"SearchInfo", searchInfo},
        {"IncludeDisabledProviders", false},
    });
    if (!query.itemId.empty()) {
        body["ItemId"] = query.itemId;
    }
    return LibraryRequest{"POST", "/Items/RemoteSearch/" + EncodeQueryComponent(query.itemType),
                          body};
}

LibraryRequest buildApplyRemoteSearchRequest(const std::string &itemId,
                                             const nlohmann::json &searchResult,
                                             bool replaceAllImages)
{
    std::string path = "/Items/RemoteSearch/Apply/" + EncodeQueryComponent(itemId) + "?";
    AppendParam(path, "replaceAllImages", replaceAllImages ? "true" : "false");
    // 服务端会把结果的 ProviderIds 直接赋给条目（`item.ProviderIds = searchResult.ProviderIds`），
    // 缺了它会让条目的外部 ID 变成 null —— 走同一套兜底
    return LibraryRequest{"POST", path, normalizeItemMetadataBody(searchResult)};
}

nlohmann::json normalizeMetadataEditorInfo(const nlohmann::json &serverJson)
{
    const nlohmann::json src = serverJson.is_object() ? serverJson : nlohmann::json::object();

    nlohmann::json ratings = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "ParentalRatingOptions")) {
        const std::string name = JsonStringOr(item, "Name");
        // 分级的"值"就是它自己（服务端按 Name 匹配 OfficialRating），没有单独的取值字段
        ratings.push_back(OptionEntry(name, name, name));
    }

    nlohmann::json countries = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "Countries")) {
        const std::string name = JsonStringOr(item, "Name");
        countries.push_back(OptionEntry(name, JsonStringOr(item, "DisplayName"),
                                        // 条目存的是两字母地区码（`CountryInfo.TwoLetterISORegionName`）
                                        JsonStringOr(item, "TwoLetterISORegionName")));
    }

    nlohmann::json cultures = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "Cultures")) {
        const std::string name = JsonStringOr(item, "Name");
        cultures.push_back(OptionEntry(name, JsonStringOr(item, "DisplayName"),
                                       // 语言用三字母码：服务端按 ThreeLetterISOLanguageName 匹配
                                       JsonStringOr(item, "ThreeLetterISOLanguageName")));
    }

    nlohmann::json externalIds = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "ExternalIdInfos")) {
        const std::string name = JsonStringOr(item, "Name");
        const std::string key = JsonStringOr(item, "Key");
        nlohmann::json entry = OptionEntry(key, name, key);
        // URL 模板给界面拼"去提供方网站看看"的链接；服务端把它当格式串（含 {0}）
        entry["urlFormatString"] = JsonStringOr(item, "UrlFormatString");
        externalIds.push_back(entry);
    }

    nlohmann::json contentTypes = nlohmann::json::array();
    for (const auto &item : JsonArrayOr(src, "ContentTypeOptions")) {
        const std::string name = JsonStringOr(item, "Name");
        const std::string value = JsonStringOr(item, "Value");
        contentTypes.push_back(OptionEntry(value, name, value));
    }

    return nlohmann::json::object({
        {"parentalRatings", ratings},
        {"countries", countries},
        {"cultures", cultures},
        {"externalIdInfos", externalIds},
        {"contentType", JsonStringOr(src, "ContentType")},
        {"contentTypeOptions", contentTypes},
    });
}

nlohmann::json normalizeRemoteSearchResults(const nlohmann::json &serverJson)
{
    nlohmann::json out = nlohmann::json::array();
    if (!serverJson.is_array()) {
        return out;
    }
    for (const auto &item : serverJson) {
        if (!item.is_object()) {
            continue;
        }
        nlohmann::json entry = nlohmann::json::object({
            {"name", JsonStringOr(item, "Name")},
            {"overview", JsonStringOr(item, "Overview")},
            {"imageUrl", JsonStringOr(item, "ImageUrl")},
            {"premiereDate", JsonStringOr(item, "PremiereDate")},
            {"searchProviderName", JsonStringOr(item, "SearchProviderName")},
            {"providerIds", item.contains("ProviderIds") && item["ProviderIds"].is_object()
                                ? item["ProviderIds"]
                                : nlohmann::json::object()},
            // 回传"应用识别结果"时要原样带上（服务端只认 RemoteSearchResult 原文）
            {"raw", item},
        });
        // 可空数字保持可空：界面上"没有年份"与"年份是 0"是两件事
        entry["year"] = item.contains("ProductionYear") && item["ProductionYear"].is_number()
                            ? item["ProductionYear"]
                            : nlohmann::json(nullptr);
        entry["indexNumber"] = item.contains("IndexNumber") && item["IndexNumber"].is_number()
                                   ? item["IndexNumber"]
                                   : nlohmann::json(nullptr);
        entry["parentIndexNumber"] =
            item.contains("ParentIndexNumber") && item["ParentIndexNumber"].is_number()
                ? item["ParentIndexNumber"]
                : nlohmann::json(nullptr);
        out.push_back(entry);
    }
    return out;
}

nlohmann::json normalizeItemMetadataBody(const nlohmann::json &body)
{
    nlohmann::json out = body.is_object() ? body : nlohmann::json::object();

    // 服务端 `request.ProviderIds.ToList()` 没有 null 保护：缺了它直接 500
    if (!out.contains("ProviderIds") || !out["ProviderIds"].is_object()) {
        out["ProviderIds"] = nlohmann::json::object();
    }
    // 外部 ID 的空值会被服务端主动删掉（`string.IsNullOrEmpty(pair.Value)`），但 null 值不是
    // 字符串、会在那边炸在 `IsNullOrEmpty` 上，所以这里先清掉非字符串项
    for (auto it = out["ProviderIds"].begin(); it != out["ProviderIds"].end();) {
        if (!it.value().is_string()) {
            it = out["ProviderIds"].erase(it);
        } else {
            ++it;
        }
    }

    // `Studios` 服务端取 `.Name`：界面把它当字符串列表编辑，两种形状都要能收
    if (out.contains("Studios") && out["Studios"].is_array()) {
        nlohmann::json studios = nlohmann::json::array();
        for (const auto &item : out["Studios"]) {
            if (item.is_string()) {
                const std::string name = Trimmed(item.get<std::string>());
                if (!name.empty()) {
                    studios.push_back(nlohmann::json::object({{"Name", name}}));
                }
            } else if (item.is_object() && item.contains("Name") && item["Name"].is_string()) {
                studios.push_back(item);
            }
        }
        out["Studios"] = studios;
    }

    return out;
}

std::string remoteSearchTypeFor(const std::string &itemType)
{
    // 10.8 的 RemoteSearch 端点只有这几个（`ItemLookupController`）；
    // 没有 Episode/Season —— 分集元数据跟着剧走，界面对这些类型不提供「识别」
    static const char *const kSupported[] = {"Movie",      "Series",      "BoxSet",
                                             "MusicVideo", "MusicArtist", "MusicAlbum",
                                             "Trailer",    "Book"};
    for (const char *candidate : kSupported) {
        if (itemType == candidate) {
            return itemType;
        }
    }
    return {};
}

const nlohmann::json &metadataFieldNames()
{
    // `MediaBrowser.Model.Entities.MetadataField` 的全部取值（顺序即枚举顺序）
    static const nlohmann::json kFields = nlohmann::json::array({
        "Cast", "Genres", "ProductionLocations", "Studios", "Tags", "Name", "Overview",
        "Runtime", "OfficialRating",
    });
    return kFields;
}

} // namespace api
} // namespace jellyfin
