#ifndef JELLYFIN_CORE_API_CLIENT_H
#define JELLYFIN_CORE_API_CLIENT_H

#include "error.h"
#include "http_client.h"

#include "app_version.h"

#include <cstddef>
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

    /**
     * 取纯文本响应（`text/plain`，例如日志文件），并只保留**结尾** `keepTailBytes` 字节。
     *
     * `data` 的形状：`{ "text": <末尾文本>, "truncated": <是否截断>, "totalBytes": <原始字节数> }`。
     * 为什么要截尾巴：服务端日志端点返回整份文件且没有 range/tail 支持
     * （`SystemController.GetLogFile`），一天的文件实测 15.5 MB，
     * 而看日志只需要最新的那几屏 —— 整份丢给 ArkTS 会白白占内存。
     */
    ApiResult getTextTail(const std::string &path, std::size_t keepTailBytes) const;

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
