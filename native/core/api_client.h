#ifndef JELLYFIN_CORE_API_CLIENT_H
#define JELLYFIN_CORE_API_CLIENT_H

#include "error.h"
#include "http_client.h"

#include "app_version.h"

#include <string>
#include <utility>

#include <nlohmann/json.hpp>

namespace jellyfin {

struct ApiResult {
    JellyfinError error;
    nlohmann::json data = nullptr;

    bool ok() const
    {
        return error.message.empty() && error.statusCode >= 200 && error.statusCode < 300;
    }
};

class JellyfinApiClient {
public:
    explicit JellyfinApiClient(HttpClient http = {});

    void setClientInfo(const std::string &clientName, const std::string &deviceName,
                       const std::string &version);

    ApiResult getJson(const std::string &path) const;
    ApiResult postJson(const std::string &path, const nlohmann::json &body) const;
    ApiResult deleteJson(const std::string &path) const;

    /** Returns Items array when present, otherwise the root array, else empty array. */
    ApiResult getJsonList(const std::string &path) const;

    HttpClient &http() { return http_; }
    const HttpClient &http() const { return http_; }

private:
    HttpHeaders authHeaders() const;
    ApiResult interpret(const HttpResponse &resp) const;
    std::string absoluteUrl(const std::string &path) const;

    HttpClient http_;
    std::string clientName_ = "Jellyfin HarmonyOS";
    std::string deviceName_ = "HarmonyOS";
    /** 客户端版本：Jellyfin 鉴权头里的 Client 版本，也是服务端 Sessions 里显示的应用版本 */
    std::string version_ = JELLYFIN_APP_VERSION;
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_CLIENT_H */
