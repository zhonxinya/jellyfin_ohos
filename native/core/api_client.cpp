#include "api_client.h"

#include "session.h"
#include "text_util.h"
#include "url_util.h"

#include <sstream>

namespace jellyfin {

JellyfinApiClient::JellyfinApiClient(HttpClient http) : http_(std::move(http)) {}

void JellyfinApiClient::setClientInfo(const std::string &clientName, const std::string &deviceName,
                                      const std::string &version)
{
    if (!clientName.empty()) {
        clientName_ = clientName;
    }
    if (!deviceName.empty()) {
        deviceName_ = deviceName;
    }
    if (!version.empty()) {
        version_ = version;
    }
}

HttpHeaders JellyfinApiClient::authHeaders() const
{
    auto &session = SessionManager::instance();
    std::ostringstream auth;
    auth << "MediaBrowser Client=\"" << clientName_ << "\", "
         << "Device=\"" << deviceName_ << "\", "
         << "DeviceId=\"" << session.deviceId() << "\", "
         << "Version=\"" << version_ << "\"";
    const std::string token = session.accessToken();
    if (!token.empty()) {
        auth << ", Token=\"" << token << "\"";
    }

    HttpHeaders headers;
    headers["X-Emby-Authorization"] = auth.str();
    headers["Authorization"] = auth.str();
    return headers;
}

std::string JellyfinApiClient::absoluteUrl(const std::string &path) const
{
    return JoinUrl(SessionManager::instance().baseUrl(), path);
}

ApiResult JellyfinApiClient::interpret(const HttpResponse &resp) const
{
    ApiResult result;
    if (!resp.error.empty()) {
        result.error.statusCode = 0;
        result.error.message = resp.error;
        return result;
    }
    result.error.statusCode = resp.status;
    if (resp.status < 200 || resp.status >= 300) {
        result.error.message = "HTTP " + std::to_string(resp.status);
        if (!resp.body.empty()) {
            try {
                auto j = nlohmann::json::parse(resp.body);
                if (j.contains("message") && j["message"].is_string()) {
                    result.error.message = j["message"].get<std::string>();
                } else if (j.is_string()) {
                    result.error.message = j.get<std::string>();
                }
                result.data = j;
            } catch (...) {
                // Keep status text; do not attach raw body as sensitive dump.
            }
        }
        return result;
    }

    if (resp.body.empty()) {
        result.data = nlohmann::json::object();
        return result;
    }
    try {
        result.data = nlohmann::json::parse(resp.body);
    } catch (const std::exception &ex) {
        result.error.statusCode = 0;
        result.error.message = std::string("JSON parse error: ") + ex.what();
    }
    return result;
}

ApiResult JellyfinApiClient::getJson(const std::string &path) const
{
    if (SessionManager::instance().baseUrl().empty()) {
        ApiResult r;
        r.error.message = "Server not configured";
        return r;
    }
    return interpret(http_.get(absoluteUrl(path), authHeaders()));
}

ApiResult JellyfinApiClient::postJson(const std::string &path, const nlohmann::json &body) const
{
    if (SessionManager::instance().baseUrl().empty()) {
        ApiResult r;
        r.error.message = "Server not configured";
        return r;
    }
    auto headers = authHeaders();
    headers["Content-Type"] = "application/json";
    const std::string payload = body.is_null() ? std::string() : body.dump();
    return interpret(http_.post(absoluteUrl(path), payload, headers));
}

ApiResult JellyfinApiClient::deleteJson(const std::string &path) const
{
    if (SessionManager::instance().baseUrl().empty()) {
        ApiResult r;
        r.error.message = "Server not configured";
        return r;
    }
    return interpret(http_.del(absoluteUrl(path), authHeaders()));
}

ApiResult JellyfinApiClient::getJsonList(const std::string &path) const
{
    ApiResult result = getJson(path);
    if (!result.ok()) {
        return result;
    }
    if (result.data.is_array()) {
        return result;
    }
    if (result.data.is_object() && result.data.contains("Items") && result.data["Items"].is_array()) {
        result.data = result.data["Items"];
        return result;
    }
    result.data = nlohmann::json::array();
    return result;
}

ApiResult JellyfinApiClient::getTextTail(const std::string &path, std::size_t keepTailBytes) const
{
    if (SessionManager::instance().baseUrl().empty()) {
        ApiResult r;
        r.error.message = "Server not configured";
        return r;
    }
    const HttpResponse resp = http_.get(absoluteUrl(path), authHeaders());
    ApiResult result;
    if (!resp.error.empty()) {
        result.error.statusCode = 0;
        result.error.message = resp.error;
        return result;
    }
    result.error.statusCode = resp.status;
    if (resp.status < 200 || resp.status >= 300) {
        result.error.message = "HTTP " + std::to_string(resp.status);
        return result;
    }
    bool truncated = false;
    const std::string tail = TailBytes(resp.body, keepTailBytes, truncated);
    result.data = nlohmann::json::object({
        {"text", tail},
        {"truncated", truncated},
        {"totalBytes", static_cast<int>(resp.body.size())},
    });
    return result;
}

} // namespace jellyfin
