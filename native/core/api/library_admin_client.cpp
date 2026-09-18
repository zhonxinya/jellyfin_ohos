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

} // namespace api
} // namespace jellyfin
