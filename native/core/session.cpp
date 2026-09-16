#include "session.h"

#include "url_util.h"

#include <random>

namespace jellyfin {
namespace {

std::string GenerateDeviceId()
{
    static const char *kHex = "0123456789abcdef";
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> dist(0, 15);
    std::string id = "hmos-";
    for (int i = 0; i < 16; ++i) {
        id.push_back(kHex[dist(gen)]);
    }
    return id;
}

} // namespace

SessionManager &SessionManager::instance()
{
    static SessionManager mgr;
    return mgr;
}

SessionManager::SessionManager() : deviceId_(GenerateDeviceId()) {}

void SessionManager::configureServer(const std::string &baseUrl, const std::string &serverName,
                                     const std::string &deviceId)
{
    std::lock_guard<std::mutex> lock(mutex_);
    baseUrl_ = NormalizeBaseUrl(baseUrl);
    if (!serverName.empty()) {
        serverName_ = serverName;
    }
    if (!deviceId.empty()) {
        deviceId_ = deviceId;
    } else if (deviceId_.empty()) {
        deviceId_ = GenerateDeviceId();
    }
}

void SessionManager::setAuth(const std::string &accessToken, const std::string &userId,
                             const std::string &userName, bool isAdmin)
{
    std::lock_guard<std::mutex> lock(mutex_);
    accessToken_ = accessToken;
    userId_ = userId;
    userName_ = userName;
    isAdmin_ = isAdmin;
}

void SessionManager::clearAuth()
{
    std::lock_guard<std::mutex> lock(mutex_);
    accessToken_.clear();
    userId_.clear();
    userName_.clear();
    isAdmin_ = false;
}

std::string SessionManager::baseUrl() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return baseUrl_;
}

std::string SessionManager::accessToken() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return accessToken_;
}

std::string SessionManager::userId() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return userId_;
}

std::string SessionManager::userName() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return userName_;
}

bool SessionManager::isAdmin() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return isAdmin_;
}

std::string SessionManager::serverName() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return serverName_;
}

void SessionManager::setDeviceId(const std::string &deviceId)
{
    if (!deviceId.empty()) {
        deviceId_ = deviceId;
    }
}

std::string SessionManager::deviceId() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return deviceId_;
}

bool SessionManager::isAuthenticated() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return !accessToken_.empty() && !userId_.empty();
}

nlohmann::json SessionManager::preferences() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return preferences_;
}

void SessionManager::setPreference(const std::string &key, const nlohmann::json &value)
{
    std::lock_guard<std::mutex> lock(mutex_);
    preferences_[key] = value;
}

void SessionManager::setPreferences(const nlohmann::json &prefs)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (prefs.is_object()) {
        preferences_ = prefs;
    }
}

nlohmann::json SessionManager::toJson() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    nlohmann::json j;
    j["baseUrl"] = baseUrl_;
    j["accessToken"] = accessToken_;
    j["userId"] = userId_;
    j["userName"] = userName_;
    j["isAdmin"] = isAdmin_;
    j["serverName"] = serverName_;
    j["deviceId"] = deviceId_;
    j["preferences"] = preferences_;
    return j;
}

bool SessionManager::fromJson(const nlohmann::json &j)
{
    if (!j.is_object()) {
        return false;
    }
    nlohmann::json src = j;
    if (!j.contains("accessToken") && j.contains("data") && j["data"].is_object()) {
        src = j["data"];
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (src.contains("baseUrl") && src["baseUrl"].is_string()) {
        baseUrl_ = NormalizeBaseUrl(src["baseUrl"].get<std::string>());
    }
    if (src.contains("accessToken") && src["accessToken"].is_string()) {
        accessToken_ = src["accessToken"].get<std::string>();
    }
    if (src.contains("userId") && src["userId"].is_string()) {
        userId_ = src["userId"].get<std::string>();
    }
    if (src.contains("userName") && src["userName"].is_string()) {
        userName_ = src["userName"].get<std::string>();
    }
    if (src.contains("isAdmin") && src["isAdmin"].is_boolean()) {
        isAdmin_ = src["isAdmin"].get<bool>();
    }
    if (src.contains("serverName") && src["serverName"].is_string()) {
        serverName_ = src["serverName"].get<std::string>();
    }
    if (src.contains("deviceId") && src["deviceId"].is_string() &&
        !src["deviceId"].get<std::string>().empty()) {
        deviceId_ = src["deviceId"].get<std::string>();
    }
    if (src.contains("preferences") && src["preferences"].is_object()) {
        preferences_ = src["preferences"];
    }
    return true;
}

bool SessionManager::fromJsonString(const std::string &s, std::string &error)
{
    try {
        auto j = nlohmann::json::parse(s);
        if (!fromJson(j)) {
            error = "Session JSON must be an object";
            return false;
        }
        return true;
    } catch (const std::exception &ex) {
        error = ex.what();
        return false;
    }
}

} // namespace jellyfin
