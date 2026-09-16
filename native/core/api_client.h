#ifndef JELLYFIN_CORE_API_CLIENT_H
#define JELLYFIN_CORE_API_CLIENT_H

#include "error.h"
#include "http_client.h"

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
    std::string version_ = "0.1.0";
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_CLIENT_H */
