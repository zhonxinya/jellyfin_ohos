/**
 * 媒体库管理里**依赖 HTTP 客户端**的那一层（`execute` 与两个组合入口）。
 *
 * 单独成文件的原因：`JellyfinApiClient` 的实现在 `api_client.cpp`，而它又拖进
 * `session.cpp` / `http_client.cpp` / `http_tls.cpp`(mbedTLS)。主机侧单测只需要
 * `library_admin_api.cpp` 里的纯函数（请求构造 + 响应归一化），把这一层分出去后，
 * 单测就能只链接 `library_admin_api.cpp` + `url_util.cpp`，不需要任何 IO 依赖。
 */

#include "library_admin_api.h"

namespace jellyfin {
namespace api {

ApiResult execute(JellyfinApiClient &client, const LibraryRequest &request)
{
    if (request.method == "GET") {
        return client.getJson(request.path);
    }
    if (request.method == "DELETE") {
        return client.deleteJson(request.path);
    }
    return client.postJson(request.path, request.body);
}

ApiResult getVirtualFolders(JellyfinApiClient &client)
{
    ApiResult result = execute(client, buildVirtualFoldersRequest());
    if (!result.ok()) {
        return result;
    }
    result.data = normalizeVirtualFolders(result.data);
    return result;
}

ApiResult getLocalization(JellyfinApiClient &client)
{
    ApiResult cultures = execute(client, buildLocalizationCulturesRequest());
    if (!cultures.ok()) {
        return cultures;
    }
    ApiResult countries = execute(client, buildLocalizationCountriesRequest());
    if (!countries.ok()) {
        return countries;
    }
    ApiResult combined;
    combined.error.statusCode = 200;
    combined.data = nlohmann::json::object({
        {"cultures", cultures.data.is_array() ? cultures.data : nlohmann::json::array()},
        {"countries", countries.data.is_array() ? countries.data : nlohmann::json::array()},
    });
    return combined;
}

ApiResult getMetadataSettings(JellyfinApiClient &client)
{
    // 1) 整份服务器配置（元数据抓取器配置就在 ServerConfiguration.MetadataOptions 里；
    //    keyed 路由 `/System/Configuration/metadataoptions` 实测 404）
    ApiResult config = execute(client, buildServerConfigurationRequest());
    if (!config.ok()) {
        return config;
    }

    // 2) 每个内容类型各查一次可选项再合并：10.8 没有"一次拿全部条目类型"的端点
    //    （`GetRepresentativeItemTypes(null)` 只返回 Series/Season/Episode/Movie）
    nlohmann::json available = nlohmann::json::array();
    for (const std::string &contentType : metadataContentTypes()) {
        ApiResult options =
            execute(client, buildAvailableOptionsRequest(contentType, /*isNewLibrary=*/false));
        if (options.ok()) {
            available.push_back(options.data);
        }
    }
    if (available.empty()) {
        // 一个都拿不到时不要把页面做成空的：把错误往上抛，让界面能显示原因
        return execute(client, buildAvailableOptionsRequest("movies", false));
    }

    ApiResult result;
    result.error.statusCode = 200;
    result.data = buildMetadataSettingsModel(config.data, available);
    return result;
}

} // namespace api
} // namespace jellyfin
