/**
 * 条目元数据管理（`native/core/api/item_metadata_api.*`）的主机侧单测。
 *
 * 只测**纯函数**：请求构造（方法 / 路径 / query / 请求体形状）与响应归一化。
 * 这一块最容易错、又最难在设备上定位的是"整体替换"的字段完整性 ——
 * `POST /Items/{itemId}` 会把请求里**没带的字段写空**（`item.Genres = request.Genres`），
 * 其中 `IsLocked = request.LockData ?? false` 会**静默解锁**，`ProviderIds` 缺了直接 500。
 * 所以这里卡三件事：
 *   1. `GET` 的 `Fields` 覆盖全部被门控的可编辑字段（少一个 = 回传时清空一个）；
 *   2. `POST` 的请求体原样保留不认识的字段，只对服务端会崩的两处（ProviderIds / Studios）兜底；
 *   3. 归一化把服务端各 DTO 收敛成界面能直接画的形状。
 *
 * 构建（仓库根目录）：
 *   g++ -std=c++17 -pthread -I native/core -I native/core/api -I native/third_party \
 *       native/core/tests/test_item_metadata_api.cpp \
 *       native/core/api/item_metadata_api.cpp native/core/url_util.cpp -o test_item_metadata_api
 */

#include "item_metadata_api.h"

#include <algorithm>
#include <iostream>
#include <string>

using jellyfin::api::LibraryRequest;
using jellyfin::api::RemoteSearchQuery;

namespace {

int gFailures = 0;

void ExpectEq(const std::string &name, const std::string &got, const std::string &want)
{
    if (got != want) {
        std::cerr << "FAIL " << name << "\n  got =[" << got << "]\n  want=[" << want << "]\n";
        ++gFailures;
    } else {
        std::cout << "ok   " << name << "\n";
    }
}

void ExpectTrue(const std::string &name, bool cond)
{
    if (!cond) {
        std::cerr << "FAIL " << name << "\n";
        ++gFailures;
    } else {
        std::cout << "ok   " << name << "\n";
    }
}

void ExpectJsonEq(const std::string &name, const nlohmann::json &got, const nlohmann::json &want)
{
    if (got != want) {
        std::cerr << "FAIL " << name << "\n  got =" << got.dump() << "\n  want=" << want.dump()
                  << "\n";
        ++gFailures;
    } else {
        std::cout << "ok   " << name << "\n";
    }
}

/** `Fields` 里是否列出了某个字段（服务端按逗号分隔的枚举名匹配）。 */
bool FieldsContain(const std::string &path, const std::string &field)
{
    const std::string needle = "Fields=";
    const std::size_t at = path.find(needle);
    if (at == std::string::npos) {
        return false;
    }
    const std::string value = path.substr(at + needle.size());
    std::size_t begin = 0;
    while (begin <= value.size()) {
        const std::size_t end = value.find(',', begin);
        const std::string token = value.substr(begin, end == std::string::npos ? std::string::npos
                                                                              : end - begin);
        if (token == field) {
            return true;
        }
        if (end == std::string::npos) {
            break;
        }
        begin = end + 1;
    }
    return false;
}

void TestItemMetadataRequest()
{
    const LibraryRequest request = jellyfin::api::buildItemMetadataRequest("user-1", "item-1");
    ExpectEq("itemMetadata.method", request.method, "GET");
    ExpectEq("itemMetadata.path", request.path,
             "/Users/user-1/Items/item-1?Fields=" +
                 std::string(jellyfin::api::kItemMetadataEditFields));
    ExpectTrue("itemMetadata.body 为空", request.body.is_null());

    // 被 ItemFields 门控的字段：不请求就不返回，不返回 + 整体替换 = 静默清空
    const char *const gated[] = {"ProviderIds", "Genres",       "Tags",      "Studios",
                                 "Overview",    "Taglines",     "SortName",  "CustomRating",
                                 "OriginalTitle", "DateCreated", "Settings", "ProductionLocations"};
    for (const char *field : gated) {
        ExpectTrue("Fields 含 " + std::string(field), FieldsContain(request.path, field));
    }
    // Settings 同时管这几个字段，必须有（最容易漏的就是它）
    ExpectTrue("Fields 含 Settings（管 LockedFields/CriticRating/首选语言）",
               FieldsContain(request.path, "Settings"));

    // id 必须被编码：真实 id 是 32 位十六进制不带特殊字符，但 userId 未必
    const LibraryRequest encoded = jellyfin::api::buildItemMetadataRequest("u 1", "i/2");
    ExpectTrue("itemMetadata.userId 空格编成 %20",
               encoded.path.find("/Users/u%201/Items/i%2F2?") == 0);
}

void TestEditorAndExternalIdRequests()
{
    const LibraryRequest editor = jellyfin::api::buildMetadataEditorRequest("abc123");
    ExpectEq("editor.method", editor.method, "GET");
    ExpectEq("editor.path", editor.path, "/Items/abc123/MetadataEditor");

    const LibraryRequest ids = jellyfin::api::buildExternalIdInfosRequest("abc123");
    ExpectEq("externalIds.method", ids.method, "GET");
    ExpectEq("externalIds.path", ids.path, "/Items/abc123/ExternalIdInfos");
}

void TestUpdateContentTypeRequest()
{
    const LibraryRequest set =
        jellyfin::api::buildUpdateContentTypeRequest("item-1", "movies");
    ExpectEq("contentType.method", set.method, "POST");
    ExpectEq("contentType.path", set.path, "/Items/item-1/ContentType?contentType=movies");

    // 空串 = 清除覆盖（回到从媒体库继承），此时 query 必须还在（服务端按它判断"没有值"）
    const LibraryRequest clear = jellyfin::api::buildUpdateContentTypeRequest("i 2", "");
    ExpectEq("contentType.clearPath", clear.path, "/Items/i%202/ContentType?contentType=");
}

void TestUpdateItemRequest()
{
    // 完整条目原文（含本模块不认识的字段）：必须**原样**回传，整体替换才安全
    const nlohmann::json item = nlohmann::json::object({
        {"Name", "东方快车谋杀案"},
        {"Overview", "简介"},
        {"Genres", nlohmann::json::array({"悬疑", "犯罪"})},
        {"Tags", nlohmann::json::array({"4K"})},
        {"Studios", nlohmann::json::array({nlohmann::json::object({{"Name", "20 世纪影业"}})})},
        {"ProviderIds", nlohmann::json::object({{"Tmdb", "4176"}})},
        {"LockData", true},
        {"LockedFields", nlohmann::json::array({"Name"})},
        {"ProductionYear", 2017},
        {"CriticRating", 60},
        // 不认识的字段（服务端会忽略，但丢掉它就可能踩到"没带 = 清空"）
        {"SomeFutureField", "keep-me"},
        {"UserData", nlohmann::json::object({{"Played", false}})},
    });
    const LibraryRequest request = jellyfin::api::buildUpdateItemRequest("item-1", item);
    ExpectEq("updateItem.method", request.method, "POST");
    ExpectEq("updateItem.path", request.path, "/Items/item-1");
    ExpectJsonEq("updateItem.body 原样保留", request.body, item);
    // 锁定状态必须回传：`IsLocked = request.LockData ?? false` —— 少了它就解锁
    ExpectJsonEq("updateItem 保留 LockData", request.body["LockData"], true);
    ExpectJsonEq("updateItem 保留 LockedFields", request.body["LockedFields"],
                 nlohmann::json::array({"Name"}));
    ExpectJsonEq("updateItem 保留未知字段", request.body["SomeFutureField"], "keep-me");
}

void TestNormalizeItemMetadataBody()
{
    // ProviderIds 缺失：服务端 `request.ProviderIds.ToList()` 无 null 保护 → 必须补成对象
    const nlohmann::json missing = nlohmann::json::object({{"Name", "x"}});
    const nlohmann::json fixed = jellyfin::api::normalizeItemMetadataBody(missing);
    ExpectJsonEq("body.ProviderIds 缺失时补空对象", fixed["ProviderIds"],
                 nlohmann::json::object());
    ExpectTrue("body.ProviderIds 是对象", fixed["ProviderIds"].is_object());

    // ProviderIds 为 null / 非对象同样兜底
    const nlohmann::json nullIds = jellyfin::api::normalizeItemMetadataBody(
        nlohmann::json::object({{"ProviderIds", nullptr}}));
    ExpectJsonEq("body.ProviderIds=null 时补空对象", nullIds["ProviderIds"],
                 nlohmann::json::object());

    // 非字符串的外部 ID 值会让服务端炸在 IsNullOrEmpty 上：清掉
    const nlohmann::json dirty = jellyfin::api::normalizeItemMetadataBody(nlohmann::json::object({
        {"ProviderIds", nlohmann::json::object({{"Tmdb", "4176"}, {"Bad", 7}})},
    }));
    ExpectJsonEq("body.ProviderIds 清掉非字符串项", dirty["ProviderIds"],
                 nlohmann::json::object({{"Tmdb", "4176"}}));

    // Studios：界面当字符串列表编辑，服务端要 `{Name}`
    const nlohmann::json studios = jellyfin::api::normalizeItemMetadataBody(nlohmann::json::object({
        {"Studios", nlohmann::json::array({" 华纳 ", "", nlohmann::json::object({{"Name", "A24"}}),
                                           nlohmann::json::object({{"Id", "no-name"}})})},
    }));
    ExpectJsonEq("body.Studios 转成 NameGuidPair[]", studios["Studios"],
                 nlohmann::json::array({nlohmann::json::object({{"Name", "华纳"}}),
                                        nlohmann::json::object({{"Name", "A24"}})}));

    // AlbumArtists / ArtistItems 同为 `NameGuidPair[]`：界面按字符串列表编辑，
    // 只发字符串会被服务端反序列化失败（服务端取 `.Select(i => i.Name)`）
    const nlohmann::json music = jellyfin::api::normalizeItemMetadataBody(nlohmann::json::object({
        {"AlbumArtists", nlohmann::json::array({" 周杰伦 ", ""})},
        {"ArtistItems", nlohmann::json::array(
            {nlohmann::json::object({{"Name", "费玉清"}, {"Id", "a-1"}})})},
    }));
    ExpectJsonEq("body.AlbumArtists 转成 NameGuidPair[]", music["AlbumArtists"],
                 nlohmann::json::array({nlohmann::json::object({{"Name", "周杰伦"}})}));
    ExpectJsonEq("body.ArtistItems 对象形状透传（保留 Id）", music["ArtistItems"],
                 nlohmann::json::array(
                     {nlohmann::json::object({{"Name", "费玉清"}, {"Id", "a-1"}})}));

    // 字段缺失时**不能**凭空补空数组：服务端 `item.AlbumArtists = request.AlbumArtists...`
    // 会把专辑艺术家清空，而字段缺失时服务端会跳过
    const nlohmann::json noMusic = jellyfin::api::normalizeItemMetadataBody(
        nlohmann::json::object({{"Name", "x"}}));
    ExpectTrue("body 缺 AlbumArtists 时不补字段", !noMusic.contains("AlbumArtists"));
    ExpectTrue("body 缺 ArtistItems 时不补字段", !noMusic.contains("ArtistItems"));

    // 用户清空是合法意图：空数组保持空数组
    const nlohmann::json clearedArtists = jellyfin::api::normalizeItemMetadataBody(
        nlohmann::json::object({{"AlbumArtists", nlohmann::json::array()}}));
    ExpectJsonEq("body.空 AlbumArtists 保持空数组", clearedArtists["AlbumArtists"],
                 nlohmann::json::array());

    // 空数组保持空数组（用户清空标签是合法意图，不能变成 null/缺字段之外的东西）
    const nlohmann::json cleared = jellyfin::api::normalizeItemMetadataBody(
        nlohmann::json::object({{"Genres", nlohmann::json::array()}}));
    ExpectJsonEq("body.空 Genres 保持空数组", cleared["Genres"], nlohmann::json::array());

    // 非对象输入不能抛（NAPI 边界来的可能是 null）
    const nlohmann::json fromNull = jellyfin::api::normalizeItemMetadataBody(nullptr);
    ExpectTrue("body.null 输入得到空对象", fromNull.is_object());
    ExpectTrue("body.null 输入也有 ProviderIds", fromNull.contains("ProviderIds"));
}

void TestRemoteSearchRequest()
{
    RemoteSearchQuery query;
    query.itemType = "Movie";
    query.itemId = "item-1";
    query.searchTerm = "东方快车";
    query.year = 2017;
    query.metadataLanguage = "zho";
    query.metadataCountryCode = "CN";

    const LibraryRequest request = jellyfin::api::buildRemoteSearchRequest(query);
    ExpectEq("remoteSearch.method", request.method, "POST");
    ExpectEq("remoteSearch.path", request.path, "/Items/RemoteSearch/Movie");
    ExpectJsonEq("remoteSearch.SearchInfo.Name", request.body["SearchInfo"]["Name"], "东方快车");
    // 手动搜索：默认 true 是"自动"，这里必须显式 false（与 ItemRefreshController 一致）
    ExpectJsonEq("remoteSearch.SearchInfo.IsAutomated", request.body["SearchInfo"]["IsAutomated"],
                 false);
    ExpectJsonEq("remoteSearch.SearchInfo.Year", request.body["SearchInfo"]["Year"], 2017);
    ExpectJsonEq("remoteSearch.SearchInfo.ProviderIds 默认空对象",
                 request.body["SearchInfo"]["ProviderIds"], nlohmann::json::object());
    ExpectJsonEq("remoteSearch.SearchInfo.MetadataLanguage",
                 request.body["SearchInfo"]["MetadataLanguage"], "zho");
    ExpectJsonEq("remoteSearch.SearchInfo.MetadataCountryCode",
                 request.body["SearchInfo"]["MetadataCountryCode"], "CN");
    ExpectJsonEq("remoteSearch.ItemId", request.body["ItemId"], "item-1");
    ExpectJsonEq("remoteSearch.IncludeDisabledProviders",
                 request.body["IncludeDisabledProviders"], false);

    // year = 0 表示不限：不发该字段（服务端 Year 是可空 int）
    RemoteSearchQuery noYear;
    noYear.itemType = "Series";
    noYear.searchTerm = "xx";
    const LibraryRequest bare = jellyfin::api::buildRemoteSearchRequest(noYear);
    ExpectTrue("remoteSearch.year=0 不发 Year", !bare.body["SearchInfo"].contains("Year"));
    ExpectTrue("remoteSearch 无 itemId 不发 ItemId", !bare.body.contains("ItemId"));
    ExpectTrue("remoteSearch 无语言不发 MetadataLanguage",
               !bare.body["SearchInfo"].contains("MetadataLanguage"));

    // 按已知外部 ID 精确查（重新识别纠正 ID 的场景）
    RemoteSearchQuery byId;
    byId.itemType = "Series";
    byId.searchTerm = "剧名";
    byId.providerIds = nlohmann::json::object({{"Tvdb", "12345"}});
    const LibraryRequest idRequest = jellyfin::api::buildRemoteSearchRequest(byId);
    ExpectJsonEq("remoteSearch.ProviderIds 透传", idRequest.body["SearchInfo"]["ProviderIds"],
                 nlohmann::json::object({{"Tvdb", "12345"}}));

    // 音乐专辑：服务端 `MusicBrainzAlbumProvider` 走
    // `release/?query="{名称}" AND artist:"{GetAlbumArtist()}"`，而 `GetAlbumArtist()`
    // 只认 `AlbumInfo.AlbumArtists` —— 不带它查询退化成 `artist:""`，等于搜不出来
    RemoteSearchQuery album;
    album.itemType = "MusicAlbum";
    album.searchTerm = "范特西";
    album.albumArtists = nlohmann::json::array({" 周杰伦 ", ""});
    album.artistProviderIds = nlohmann::json::object({{"MusicBrainzArtist", "mbid-1"}});
    const LibraryRequest albumRequest = jellyfin::api::buildRemoteSearchRequest(album);
    ExpectEq("remoteSearch.album.path", albumRequest.path, "/Items/RemoteSearch/MusicAlbum");
    ExpectJsonEq("remoteSearch.AlbumArtists 去空去空白",
                 albumRequest.body["SearchInfo"]["AlbumArtists"],
                 nlohmann::json::array({"周杰伦"}));
    ExpectJsonEq("remoteSearch.ArtistProviderIds 透传",
                 albumRequest.body["SearchInfo"]["ArtistProviderIds"],
                 nlohmann::json::object({{"MusicBrainzArtist", "mbid-1"}}));

    // 没有专辑艺术家时整个省略（发空数组与"带空艺术家去查"是同一个坏结果）
    RemoteSearchQuery noArtist;
    noArtist.itemType = "MusicAlbum";
    noArtist.searchTerm = "x";
    const LibraryRequest noArtistRequest = jellyfin::api::buildRemoteSearchRequest(noArtist);
    ExpectTrue("remoteSearch 无专辑艺术家不发 AlbumArtists",
               !noArtistRequest.body["SearchInfo"].contains("AlbumArtists"));
    ExpectTrue("remoteSearch 无艺术家外部 ID 不发 ArtistProviderIds",
               !noArtistRequest.body["SearchInfo"].contains("ArtistProviderIds"));
    ExpectTrue("remoteSearch 空 artistProviderIds 不误判为对象",
               !noArtistRequest.body["SearchInfo"].contains("ArtistProviderIds"));
}

void TestApplyRemoteSearchRequest()
{
    const nlohmann::json result = nlohmann::json::object({
        {"Name", "东方快车谋杀案"},
        {"ProductionYear", 2017},
        {"ProviderIds", nlohmann::json::object({{"Tmdb", "4176"}})},
    });
    const LibraryRequest withImages =
        jellyfin::api::buildApplyRemoteSearchRequest("item-1", result, true);
    ExpectEq("apply.method", withImages.method, "POST");
    ExpectEq("apply.path", withImages.path,
             "/Items/RemoteSearch/Apply/item-1?replaceAllImages=true");
    ExpectJsonEq("apply.body 原样回传结果", withImages.body["ProviderIds"],
                 nlohmann::json::object({{"Tmdb", "4176"}}));

    const LibraryRequest withoutImages =
        jellyfin::api::buildApplyRemoteSearchRequest("item-1", result, false);
    ExpectEq("apply.replaceAllImages=false", withoutImages.path,
             "/Items/RemoteSearch/Apply/item-1?replaceAllImages=false");

    // 服务端 `item.ProviderIds = searchResult.ProviderIds`：缺了会让条目的外部 ID 变成 null
    const nlohmann::json noIds = jellyfin::api::normalizeItemMetadataBody(
        nlohmann::json::object({{"Name", "x"}}));
    ExpectTrue("apply.body ProviderIds 兜底", noIds["ProviderIds"].is_object());
}

void TestNormalizeMetadataEditorInfo()
{
    const nlohmann::json server = nlohmann::json::object({
        {"ParentalRatingOptions", nlohmann::json::array({
            nlohmann::json::object({{"Name", "PG-13"}, {"Value", 3}}),
            nlohmann::json::object({{"Name", "TV-MA"}, {"Value", 8}}),
        })},
        {"Countries", nlohmann::json::array({
            nlohmann::json::object({{"Name", "China"}, {"DisplayName", "中国"},
                                    {"TwoLetterISORegionName", "CN"},
                                    {"ThreeLetterISORegionName", "CHN"}}),
        })},
        {"Cultures", nlohmann::json::array({
            nlohmann::json::object({{"Name", "zh-CN"}, {"DisplayName", "中文（中国）"},
                                    {"TwoLetterISOLanguageName", "zh"},
                                    {"ThreeLetterISOLanguageName", "zho"},
                                    {"ThreeLetterISOLanguageNames",
                                     nlohmann::json::array({"zho", "chi"})}}),
        })},
        {"ExternalIdInfos", nlohmann::json::array({
            nlohmann::json::object({{"Name", "TMDb"}, {"Key", "Tmdb"},
                                    {"UrlFormatString", "https://www.themoviedb.org/movie/{0}"}}),
        })},
        {"ContentType", "movies"},
        {"ContentTypeOptions", nlohmann::json::array({
            nlohmann::json::object({{"Name", "继承"}, {"Value", ""}}),
            nlohmann::json::object({{"Name", "电影"}, {"Value", "movies"}}),
        })},
    });

    const nlohmann::json model = jellyfin::api::normalizeMetadataEditorInfo(server);
    ExpectEq("editor.分级取值即名称", model["parentalRatings"][0]["value"], "PG-13");
    ExpectEq("editor.分级显示名", model["parentalRatings"][0]["displayName"], "PG-13");
    ExpectEq("editor.国家取值用两字母码", model["countries"][0]["value"], "CN");
    ExpectEq("editor.国家显示名", model["countries"][0]["displayName"], "中国");
    // 语言必须用三字母码：服务端按 ThreeLetterISOLanguageName 匹配（见 docs/library-management.md）
    ExpectEq("editor.语言取值用三字母码", model["cultures"][0]["value"], "zho");
    ExpectEq("editor.语言显示名", model["cultures"][0]["displayName"], "中文（中国）");
    ExpectEq("editor.外部 ID 键", model["externalIdInfos"][0]["name"], "Tmdb");
    ExpectEq("editor.外部 ID 显示名", model["externalIdInfos"][0]["displayName"], "TMDb");
    ExpectEq("editor.外部 ID URL 模板", model["externalIdInfos"][0]["urlFormatString"],
             "https://www.themoviedb.org/movie/{0}");
    ExpectEq("editor.contentType", model["contentType"], "movies");
    ExpectEq("editor.内容类型选项显示名", model["contentTypeOptions"][0]["displayName"], "继承");
    ExpectEq("editor.内容类型选项取值", model["contentTypeOptions"][1]["value"], "movies");

    // 空/异常响应不能抛：页面在编辑器接口失败时仍要能渲染字段表单
    const nlohmann::json empty = jellyfin::api::normalizeMetadataEditorInfo(nullptr);
    ExpectTrue("editor.null 输入得到空数组", empty["cultures"].is_array() &&
                                                 empty["cultures"].empty());
    ExpectTrue("editor.null 输入仍有全部键",
               empty.contains("parentalRatings") && empty.contains("countries") &&
                   empty.contains("externalIdInfos") && empty.contains("contentTypeOptions"));
}

void TestNormalizeRemoteSearchResults()
{
    const nlohmann::json server = nlohmann::json::array({
        nlohmann::json::object({{"Name", "东方快车谋杀案"},
                                {"ProductionYear", 2017},
                                {"PremiereDate", "2017-11-03T00:00:00.0000000Z"},
                                {"ImageUrl", "https://image.tmdb.org/x.jpg"},
                                {"Overview", "简介"},
                                {"SearchProviderName", "TheMovieDb"},
                                {"ProviderIds", nlohmann::json::object({{"Tmdb", "4176"}})}}),
        // 没有年份的候选（界面上要能显示"年份未知"而不是 0）
        nlohmann::json::object({{"Name", "旧版"}, {"ProviderIds", nlohmann::json::object()}}),
    });

    const nlohmann::json results = jellyfin::api::normalizeRemoteSearchResults(server);
    ExpectTrue("search.结果条数", results.size() == 2);
    ExpectEq("search.名称", results[0]["name"], "东方快车谋杀案");
    ExpectJsonEq("search.年份", results[0]["year"], 2017);
    ExpectEq("search.图片", results[0]["imageUrl"], "https://image.tmdb.org/x.jpg");
    ExpectEq("search.提供方", results[0]["searchProviderName"], "TheMovieDb");
    ExpectEq("search.外部 ID", results[0]["providerIds"]["Tmdb"], "4176");
    // 回传"应用识别结果"要用服务端原文
    ExpectEq("search.raw 保留原文", results[0]["raw"]["Name"], "东方快车谋杀案");
    ExpectTrue("search.缺年份为 null", results[1]["year"].is_null());
    ExpectTrue("search.缺外部 ID 为空对象", results[1]["providerIds"].is_object());

    const nlohmann::json empty = jellyfin::api::normalizeRemoteSearchResults(nullptr);
    ExpectTrue("search.null 输入得到空数组", empty.is_array() && empty.empty());
}

void TestRemoteSearchTypeFor()
{
    ExpectEq("type.Movie", jellyfin::api::remoteSearchTypeFor("Movie"), "Movie");
    ExpectEq("type.Series", jellyfin::api::remoteSearchTypeFor("Series"), "Series");
    ExpectEq("type.BoxSet", jellyfin::api::remoteSearchTypeFor("BoxSet"), "BoxSet");
    ExpectEq("type.MusicAlbum", jellyfin::api::remoteSearchTypeFor("MusicAlbum"), "MusicAlbum");
    ExpectEq("type.MusicArtist", jellyfin::api::remoteSearchTypeFor("MusicArtist"), "MusicArtist");
    ExpectEq("type.MusicVideo", jellyfin::api::remoteSearchTypeFor("MusicVideo"), "MusicVideo");
    // 10.8 没有 Episode/Season 的 RemoteSearch 端点：必须返回空串，界面据此不提供「识别」
    ExpectEq("type.Episode 无端点", jellyfin::api::remoteSearchTypeFor("Episode"), "");
    ExpectEq("type.Season 无端点", jellyfin::api::remoteSearchTypeFor("Season"), "");
    ExpectEq("type.Audio 无端点", jellyfin::api::remoteSearchTypeFor("Audio"), "");
    ExpectEq("type.空串", jellyfin::api::remoteSearchTypeFor(""), "");
}

void TestMetadataFieldNames()
{
    const nlohmann::json &fields = jellyfin::api::metadataFieldNames();
    ExpectTrue("fields.是数组且非空", fields.is_array() && !fields.empty());
    ExpectTrue("fields.含 Name", std::find(fields.begin(), fields.end(), "Name") != fields.end());
    ExpectTrue("fields.含 Overview",
               std::find(fields.begin(), fields.end(), "Overview") != fields.end());
    ExpectTrue("fields.含 OfficialRating",
               std::find(fields.begin(), fields.end(), "OfficialRating") != fields.end());
}

} // namespace

int main()
{
    TestItemMetadataRequest();
    TestEditorAndExternalIdRequests();
    TestUpdateContentTypeRequest();
    TestUpdateItemRequest();
    TestNormalizeItemMetadataBody();
    TestRemoteSearchRequest();
    TestApplyRemoteSearchRequest();
    TestNormalizeMetadataEditorInfo();
    TestNormalizeRemoteSearchResults();
    TestRemoteSearchTypeFor();
    TestMetadataFieldNames();

    if (gFailures != 0) {
        std::cerr << gFailures << " failure(s)\n";
        return 1;
    }
    std::cout << "all item metadata api tests passed\n";
    return 0;
}
