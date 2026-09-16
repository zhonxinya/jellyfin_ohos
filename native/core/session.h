#ifndef JELLYFIN_CORE_SESSION_H
#define JELLYFIN_CORE_SESSION_H

#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {

/**
 * Process-wide session state. ArkTS persists the JSON blob via preferences.
 * Never log accessToken.
 */
class SessionManager {
public:
    static SessionManager &instance();

    void configureServer(const std::string &baseUrl, const std::string &serverName = {},
                         const std::string &deviceId = {});
    void setAuth(const std::string &accessToken, const std::string &userId,
                 const std::string &userName, bool isAdmin);
    void clearAuth();

    std::string baseUrl() const;
    std::string accessToken() const;
    std::string userId() const;
    std::string userName() const;
    bool isAdmin() const;
    std::string serverName() const;
    std::string deviceId() const;
    /**
     * 覆盖设备标识（应在上一次登录之前调用）。
     * 客户端把设备标识按安装持久化，启动时注入，避免"退出/重新登录"后服务端出现重复设备。
     */
    void setDeviceId(const std::string &deviceId);
    bool isAuthenticated() const;

    /** Extra client preferences (theme, etc.) stored alongside session. */
    nlohmann::json preferences() const;
    void setPreference(const std::string &key, const nlohmann::json &value);
    void setPreferences(const nlohmann::json &prefs);

    nlohmann::json toJson() const;
    bool fromJson(const nlohmann::json &j);
    bool fromJsonString(const std::string &s, std::string &error);

private:
    SessionManager();
    SessionManager(const SessionManager &) = delete;
    SessionManager &operator=(const SessionManager &) = delete;

    mutable std::mutex mutex_;
    std::string baseUrl_;
    std::string accessToken_;
    std::string userId_;
    std::string userName_;
    bool isAdmin_ = false;
    std::string serverName_;
    std::string deviceId_;
    nlohmann::json preferences_ = nlohmann::json::object();
};

} // namespace jellyfin

#endif /* JELLYFIN_CORE_SESSION_H */
