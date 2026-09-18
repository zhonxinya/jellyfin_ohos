/**
 * 媒体库管理（`native/core/api/library_admin_api.*`）的主机侧单测。
 *
 * 只测**纯函数**：请求构造（方法 / 路径 / query 编码 / 请求体形状）与响应归一化。
 * `HttpClient` 没有可注入的传输层（直接走 socket），所以"发请求"这一层不在这里测，
 * 由设备实测覆盖。这里卡住的是最容易出错、又最难在设备上定位的部分：
 * query 里的中文/空格/斜杠编码、逗号分隔数组的坑、可空数组的 null 语义、整体替换的字段完整性。
 *
 * 构建（仓库根目录）：
 *   g++ -std=c++17 -I native/core -I native/core/api -I native/third_party/nlohmann \
 *       native/core/tests/test_library_admin_api.cpp \
 *       native/core/api/library_admin_api.cpp native/core/url_util.cpp -o test_library_admin_api
 */

#include "library_admin_api.h"

#include <cstdlib>
#include <iostream>
#include <string>

using jellyfin::api::LibraryRequest;

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

void TestRequestBuilders()
{
    using namespace jellyfin::api;

    {
        const LibraryRequest r = buildVirtualFoldersRequest();
        ExpectEq("list method", r.method, "GET");
        ExpectEq("list path", r.path, "/Library/VirtualFolders");
        ExpectTrue("list no body", r.body.is_null());
    }

    {
        const LibraryRequest r = buildAvailableOptionsRequest("movies", true);
        ExpectEq("available options method", r.method, "GET");
        ExpectEq("available options path", r.path,
                 "/Libraries/AvailableOptions?libraryContentType=movies&isNewLibrary=true");
    }

    {
        const LibraryRequest r = buildAvailableOptionsRequest("", false);
        ExpectEq("available options without content type", r.path,
                 "/Libraries/AvailableOptions?isNewLibrary=false");
    }

    {
        // 媒体库名里的空格/中文/& 必须编码，否则会把 query 拆坏
        const LibraryRequest r =
            buildAddVirtualFolderRequest("我的 电影&剧", "movies", {"/media/movies"}, nullptr, true);
        ExpectEq("add method", r.method, "POST");
        ExpectEq("add path", r.path,
                 "/Library/VirtualFolders?name=%E6%88%91%E7%9A%84+%E7%94%B5%E5%BD%B1%26%E5%89%A7"
                 "&collectionType=movies&refreshLibrary=true");
        ExpectJsonEq("add body uses PathInfos",
                     r.body,
                     nlohmann::json::parse(
                         R"({"LibraryOptions":{"PathInfos":[{"Path":"/media/movies"}]}})"));
    }

    {
        // 路径**必须**走请求体：服务端把 query 里的 paths 当逗号分隔数组，
        // 而媒体路径本身可能带逗号（"电影, 收藏"），走 query 会被拆成两条不存在的路径。
        const LibraryRequest r = buildAddVirtualFolderRequest(
            "lib", "movies", {"/media/a,b", "/media/c"}, nullptr, false);
        ExpectEq("add paths stay in body",
                 r.body["LibraryOptions"]["PathInfos"].dump(),
                 R"([{"Path":"/media/a,b"},{"Path":"/media/c"}])");
        ExpectTrue("add does not put paths in query",
                   r.path.find("paths=") == std::string::npos);
    }

    {
        // 传了完整选项对象时不能被 paths 覆盖掉其它字段
        const nlohmann::json options =
            nlohmann::json::parse(R"({"EnableRealtimeMonitor":false,"SeasonZeroDisplayName":"特别篇"})");
        const LibraryRequest r =
            buildAddVirtualFolderRequest("lib", "tvshows", {"/tv"}, options, false);
        ExpectTrue("add keeps other options", r.body["LibraryOptions"]["EnableRealtimeMonitor"] == false);
        ExpectEq("add keeps season zero name",
                 r.body["LibraryOptions"]["SeasonZeroDisplayName"].get<std::string>(), "特别篇");
    }

    {
        // 语言数据源是 /Localization/Cultures：10.8.12 没有 /Localization/Languages（实测 404）
        ExpectEq("cultures path", buildLocalizationCulturesRequest().path, "/Localization/Cultures");
        ExpectEq("countries path", buildLocalizationCountriesRequest().path,
                 "/Localization/Countries");
    }

    {
        const LibraryRequest r = buildRenameVirtualFolderRequest("旧 名", "新名", false);
        ExpectEq("rename method", r.method, "POST");
        ExpectEq("rename path", r.path,
                 "/Library/VirtualFolders/Name?name=%E6%97%A7+%E5%90%8D"
                 "&newName=%E6%96%B0%E5%90%8D&refreshLibrary=false");
    }

    {
        const LibraryRequest r = buildRemoveVirtualFolderRequest("电影", true);
        ExpectEq("remove method", r.method, "DELETE");
        // DELETE 不带请求体（服务端用 query 参数）
        ExpectTrue("remove no body", r.body.is_null());
        ExpectEq("remove path", r.path,
                 "/Library/VirtualFolders?name=%E7%94%B5%E5%BD%B1&refreshLibrary=true");
    }

    {
        const LibraryRequest r = buildAddMediaPathRequest("电影", "/media/电影", "", true);
        ExpectEq("add path method", r.method, "POST");
        ExpectEq("add path route", r.path, "/Library/VirtualFolders/Paths?refreshLibrary=true");
        // Path 与 PathInfo.Path 都要给：控制器优先用 PathInfo，缺失时回落到 Path
        ExpectJsonEq("add path body", r.body,
                     nlohmann::json::parse(
                         R"({"Name":"电影","Path":"/media/电影",)"
                         R"("PathInfo":{"Path":"/media/电影","NetworkPath":null}})"));
    }

    {
        const LibraryRequest r =
            buildAddMediaPathRequest("电影", "/media/m", "smb://nas/media", false);
        ExpectEq("add path network path",
                 r.body["PathInfo"]["NetworkPath"].get<std::string>(), "smb://nas/media");
    }

    {
        const LibraryRequest r = buildUpdateMediaPathRequest("电影", "/media/m", "");
        ExpectEq("update path method", r.method, "POST");
        ExpectEq("update path route", r.path, "/Library/VirtualFolders/Paths/Update");
        ExpectTrue("update path no Name query",
                   r.path.find("?") == std::string::npos);
        ExpectEq("update path body name", r.body["Name"].get<std::string>(), "电影");
        ExpectTrue("update path network null", r.body["PathInfo"]["NetworkPath"].is_null());
    }

    {
        const LibraryRequest r = buildRemoveMediaPathRequest("电影", "/media/a b", true);
        ExpectEq("remove path method", r.method, "DELETE");
        // 路径必须编码：空格 → '+'，斜杠 → %2F（服务端 query 解码会还原成 '/'）
        ExpectEq("remove path query", r.path,
                 "/Library/VirtualFolders/Paths?name=%E7%94%B5%E5%BD%B1"
                 "&path=%2Fmedia%2Fa+b&refreshLibrary=true");
    }

    {
        const nlohmann::json options =
            nlohmann::json::parse(R"({"EnablePhotos":false,"MetadataSavers":["Nfo"]})");
        const LibraryRequest r = buildUpdateLibraryOptionsRequest("abc123", options);
        ExpectEq("update options route", r.path, "/Library/VirtualFolders/LibraryOptions");
        ExpectEq("update options id", r.body["Id"].get<std::string>(), "abc123");
        // 整体替换：服务端把 LibraryOptions 全量落盘，所以必须原样带上所有字段
        ExpectTrue("update options keeps unknown field",
                   r.body["LibraryOptions"]["MetadataSavers"][0] == "Nfo");
        ExpectEq("update options payload", r.body["LibraryOptions"].dump(),
                 options.dump());
    }

    {
        const LibraryRequest r = buildRefreshLibraryRequest();
        ExpectEq("refresh all method", r.method, "POST");
        ExpectEq("refresh all route", r.path, "/Library/Refresh");
    }

    {
        const LibraryRequest r = buildRefreshItemRequest("id-1", "FullRefresh", "", true, false);
        ExpectEq("refresh item route", r.path,
                 "/Items/id-1/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None"
                 "&replaceAllMetadata=true&replaceAllImages=false");
    }
}

void TestNormalizeLibraryOptions()
{
    using jellyfin::api::normalizeLibraryOptions;

    {
        // 服务端省略可空字段：不可空字段补 C# 默认值，可空数组保持"缺席"
        const nlohmann::json out = normalizeLibraryOptions(nullptr);
        ExpectTrue("defaults realtime monitor", out["EnableRealtimeMonitor"] == true);
        ExpectTrue("defaults photos", out["EnablePhotos"] == true);
        ExpectTrue("defaults series grouping", out["EnableAutomaticSeriesGrouping"] == true);
        ExpectTrue("defaults skip subtitles if audio matches",
                   out["SkipSubtitlesIfAudioTrackMatches"] == true);
        ExpectTrue("defaults require perfect subtitle match",
                   out["RequirePerfectSubtitleMatch"] == true);
        ExpectEq("defaults season zero", out["SeasonZeroDisplayName"].get<std::string>(), "Specials");
        ExpectEq("defaults embedded subtitles",
                 out["AllowEmbeddedSubtitles"].get<std::string>(), "AllowAll");
        ExpectTrue("defaults language empty", out["PreferredMetadataLanguage"] == "");
        ExpectTrue("defaults path infos empty", out["PathInfos"].is_array() && out["PathInfos"].empty());
        ExpectTrue("defaults type options empty",
                   out["TypeOptions"].is_array() && out["TypeOptions"].empty());
        // 可空数组：缺席就是缺席，不能补成 []（否则回传会把"继承全局"变成"全部禁用"）
        ExpectTrue("metadata savers stay absent", !out.contains("MetadataSavers"));
        ExpectTrue("subtitle languages stay absent", !out.contains("SubtitleDownloadLanguages"));
        ExpectTrue("local reader order stays absent", !out.contains("LocalMetadataReaderOrder"));
    }

    {
        // 服务端下发了空数组：必须原样保留成空数组（语义与缺席不同）
        const nlohmann::json out = normalizeLibraryOptions(
            nlohmann::json::parse(R"({"MetadataSavers":[],"SubtitleDownloadLanguages":["zh"]})"));
        ExpectTrue("explicit empty savers kept", out.contains("MetadataSavers") && out["MetadataSavers"].empty());
        ExpectEq("subtitle languages kept", out["SubtitleDownloadLanguages"].dump(), R"(["zh"])");
    }

    {
        // 未知字段原样保留（向前兼容新版本服务端新增的选项，回传时不能丢）
        const nlohmann::json out = normalizeLibraryOptions(
            nlohmann::json::parse(R"({"SomeFutureOption":7,"TypeOptions":null})"));
        ExpectTrue("unknown option preserved", out["SomeFutureOption"] == 7);
        ExpectTrue("null type options filled", out["TypeOptions"].is_array());
    }

    {
        const nlohmann::json out = normalizeLibraryOptions(nlohmann::json::parse(
            R"({"TypeOptions":[{"Type":"Movie","MetadataFetchers":["TheMovieDb"]}]})"));
        ExpectEq("type option type kept", out["TypeOptions"][0]["Type"].get<std::string>(), "Movie");
        ExpectEq("type option fetchers kept",
                 out["TypeOptions"][0]["MetadataFetchers"].dump(), R"(["TheMovieDb"])");
        ExpectTrue("type option missing arrays filled",
                   out["TypeOptions"][0]["ImageFetchers"].is_array() &&
                   out["TypeOptions"][0]["ImageFetchers"].empty());
    }
}

void TestNormalizeVirtualFolders()
{
    using jellyfin::api::normalizeVirtualFolder;
    using jellyfin::api::normalizeVirtualFolders;

    // 真实形状取自 10.8.12 的 VirtualFolderInfo + LibraryOptions
    const nlohmann::json server = nlohmann::json::parse(R"([
      {
        "Name": "电影",
        "Locations": ["/media/movies"],
        "CollectionType": "movies",
        "ItemId": "3f2c1a4b5d6e7f8091a2b3c4d5e6f708",
        "PrimaryImageItemId": "3f2c1a4b5d6e7f8091a2b3c4d5e6f708",
        "RefreshProgress": 42.5,
        "RefreshStatus": "扫描中",
        "LibraryOptions": {
          "EnableRealtimeMonitor": false,
          "PathInfos": [{"Path": "/media/movies", "NetworkPath": "smb://nas/movies"}],
          "MetadataSavers": ["Nfo"],
          "TypeOptions": [{"Type": "Movie", "MetadataFetchers": ["TheMovieDb"]}]
        }
      },
      {
        "Name": "音乐",
        "Locations": [],
        "CollectionType": "music",
        "ItemId": "00112233445566778899aabbccddeeff",
        "LibraryOptions": null
      }
    ])");

    const nlohmann::json out = normalizeVirtualFolders(server);
    ExpectTrue("two folders", out.is_array() && out.size() == 2);
    ExpectEq("folder name", out[0]["name"].get<std::string>(), "电影");
    ExpectEq("folder collection type", out[0]["collectionType"].get<std::string>(), "movies");
    ExpectEq("folder item id", out[0]["itemId"].get<std::string>(),
             "3f2c1a4b5d6e7f8091a2b3c4d5e6f708");
    ExpectEq("folder locations", out[0]["locations"].dump(), R"(["/media/movies"])");
    ExpectEq("folder path infos", out[0]["pathInfos"].dump(),
             R"([{"networkPath":"smb://nas/movies","path":"/media/movies"}])");
    ExpectTrue("folder refreshing", out[0]["refreshing"] == true);
    ExpectTrue("folder has primary image", out[0]["hasPrimaryImage"] == true);
    ExpectEq("folder refresh progress", out[0]["refreshProgress"].dump(), "42.5");

    // 选项对象必须能原样回传：键名保持服务端 PascalCase，未知字段不丢
    ExpectTrue("folder options round-trippable",
               out[0]["options"]["EnableRealtimeMonitor"] == false);
    ExpectEq("folder options savers", out[0]["options"]["MetadataSavers"].dump(), R"(["Nfo"])");
    ExpectEq("folder options type fetchers",
             out[0]["options"]["TypeOptions"][0]["MetadataFetchers"].dump(), R"(["TheMovieDb"])");
    ExpectTrue("folder options defaults filled",
               out[0]["options"]["SeasonZeroDisplayName"] == "Specials");

    ExpectTrue("second folder not refreshing", out[1]["refreshing"] == false);
    ExpectTrue("second folder progress null", out[1]["refreshProgress"].is_null());
    ExpectTrue("second folder no image", out[1]["hasPrimaryImage"] == false);
    ExpectTrue("second folder options usable",
               out[1]["options"]["EnablePhotos"] == true);

    {
        // Locations 缺失时回落到 LibraryOptions.PathInfos
        const nlohmann::json fallen = normalizeVirtualFolder(nlohmann::json::parse(
            R"({"Name":"x","LibraryOptions":{"PathInfos":[{"Path":"/p1"},{"Path":"/p2"}]}})"));
        ExpectEq("locations fallback", fallen["locations"].dump(), R"(["/p1","/p2"])");
    }

    {
        // 空结果 / 非数组 / Items 包装的三种响应都要能处理
        ExpectTrue("empty array", normalizeVirtualFolders(nlohmann::json::array()).empty());
        ExpectTrue("null response", normalizeVirtualFolders(nullptr).empty());
        const nlohmann::json wrapped =
            normalizeVirtualFolders(nlohmann::json::parse(R"({"Items":[{"Name":"a"}]})"));
        ExpectTrue("items wrapper", wrapped.size() == 1 && wrapped[0]["name"] == "a");
    }
}

void TestNormalizeAvailableOptions()
{
    using jellyfin::api::normalizeAvailableOptions;

    const nlohmann::json server = nlohmann::json::parse(R"({
      "MetadataSavers": [{"Name":"Nfo","DefaultEnabled":true},
                         {"Name":"Emby Xml","DefaultEnabled":false}],
      "MetadataReaders": [{"Name":"Nfo","DefaultEnabled":true}],
      "SubtitleFetchers": [{"Name":"Open Subtitles","DefaultEnabled":true}],
      "TypeOptions": [{
        "Type": "Movie",
        "MetadataFetchers": [{"Name":"TheMovieDb","DefaultEnabled":true}],
        "ImageFetchers": [{"Name":"TheMovieDb","DefaultEnabled":true}],
        "SupportedImageTypes": ["Primary","Backdrop"],
        "DefaultImageOptions": [{"ImageType":"Primary","Limit":1,"MinWidth":0}]
      }]
    })");

    const nlohmann::json out = normalizeAvailableOptions(server);
    ExpectEq("savers", out["metadataSavers"].dump(),
             R"([{"defaultEnabled":true,"name":"Nfo"},{"defaultEnabled":false,"name":"Emby Xml"}])");
    ExpectEq("readers", out["metadataReaders"].dump(), R"([{"defaultEnabled":true,"name":"Nfo"}])");
    ExpectEq("subtitle fetchers", out["subtitleFetchers"].dump(),
             R"([{"defaultEnabled":true,"name":"Open Subtitles"}])");
    ExpectEq("type option type", out["typeOptions"][0]["type"].get<std::string>(), "Movie");
    ExpectEq("type metadata fetchers", out["typeOptions"][0]["metadataFetchers"].dump(),
             R"([{"defaultEnabled":true,"name":"TheMovieDb"}])");
    ExpectEq("supported image types", out["typeOptions"][0]["supportedImageTypes"].dump(),
             R"(["Primary","Backdrop"])");
    ExpectEq("default image options", out["typeOptions"][0]["defaultImageOptions"].dump(),
             R"([{"imageType":"Primary","limit":1,"minWidth":0}])");

    const nlohmann::json empty = normalizeAvailableOptions(nullptr);
    ExpectTrue("empty savers", empty["metadataSavers"].is_array() && empty["metadataSavers"].empty());
    ExpectTrue("empty type options", empty["typeOptions"].is_array() && empty["typeOptions"].empty());
}

} // namespace

int main()
{
    TestRequestBuilders();
    TestNormalizeLibraryOptions();
    TestNormalizeVirtualFolders();
    TestNormalizeAvailableOptions();

    if (gFailures != 0) {
        std::cerr << gFailures << " failure(s)\n";
        return EXIT_FAILURE;
    }
    std::cout << "All library admin API tests passed\n";
    return EXIT_SUCCESS;
}
