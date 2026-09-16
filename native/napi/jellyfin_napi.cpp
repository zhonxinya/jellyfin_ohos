#include "jellyfin_napi.h"

#include "api/account_api.h"
#include "api/catalog_api.h"
#include "api/media_api.h"
#include "api/playback_api.h"
#include "api/playlist_api.h"
#include "api/system_api.h"
#include "api/user_items_api.h"
#include "api_client.h"
#include "engine.h"
#include "image_cache.h"
#include "image_url.h"
#include "playback_policy.h"
#include "session.h"
#include "url_util.h"
#include "version.h"

// Player version header shares the name version.h; include via relative path.
#include "../player/version.h"

#include <cctype>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace {

constexpr const char *kNativeVersion = "0.1.0-native";

jellyfin::JellyfinApiClient &Api()
{
    // 交互式请求读超时从默认 30s 收紧到 15s：
    // 设备实测遇到过服务端对个别端点"挂起不响应"（如 /Users/{uid}/Items/{personId}，
    // curl 12s 无响应），30s 等待会让界面看起来像卡死；收紧后可更快落到错误态 + 重试入口。
    static jellyfin::JellyfinApiClient client = []() {
        jellyfin::HttpClient http;
        http.setReadTimeoutSec(15);
        return jellyfin::JellyfinApiClient(std::move(http));
    }();
    return client;
}

jellyfin::api::ProgressReporter &Progress()
{
    static jellyfin::api::ProgressReporter reporter(std::chrono::seconds(10));
    return reporter;
}

std::string CurrentItemId;
std::string CurrentPlaySessionId;
std::string CurrentMediaSourceId;
std::mutex g_playbackMutex;

nlohmann::json MakeResult(bool ok, int code, const std::string &message,
                          const nlohmann::json &data = nullptr)
{
    nlohmann::json j;
    j["ok"] = ok;
    j["code"] = code;
    j["message"] = message;
    if (data.is_null()) {
        j["data"] = nullptr;
    } else {
        j["data"] = data;
    }
    return j;
}

nlohmann::json FromApi(const jellyfin::ApiResult &r)
{
    if (!r.ok()) {
        return MakeResult(false, r.error.statusCode, r.error.message,
                          r.data.is_null() ? nlohmann::json(nullptr) : r.data);
    }
    return MakeResult(true, r.error.statusCode == 0 ? 200 : r.error.statusCode, "ok", r.data);
}

std::string JsonStringField(const nlohmann::json &obj, const char *key)
{
    if (!obj.is_object() || !obj.contains(key) || !obj[key].is_string()) {
        return {};
    }
    return obj[key].get<std::string>();
}

std::string JsonStringAny(const nlohmann::json &obj, std::initializer_list<const char *> keys)
{
    for (const char *key : keys) {
        const std::string value = JsonStringField(obj, key);
        if (!value.empty()) {
            return value;
        }
    }
    return {};
}

napi_value ToNapiString(napi_env env, const std::string &s)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

struct AsyncWork {
    std::function<std::string()> fn;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

/**
 * Run blocking work on a libuv worker thread and resolve a Promise with the
 * resulting JSON string, keeping the ArkTS main thread responsive.
 */
napi_value RunAsync(napi_env env, std::function<std::string()> fn)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto *ctx = new AsyncWork{std::move(fn), {}, deferred, nullptr};
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "jellyfinAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void *data) {
            auto *c = static_cast<AsyncWork *>(data);
            c->result = c->fn();
        },
        [](napi_env env, napi_status, void *data) {
            auto *c = static_cast<AsyncWork *>(data);
            napi_value result = nullptr;
            napi_create_string_utf8(env, c->result.c_str(), NAPI_AUTO_LENGTH, &result);
            napi_resolve_deferred(env, c->deferred, result);
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value ToNapiJson(napi_env env, const nlohmann::json &j)
{
    return ToNapiString(env, j.dump());
}

bool ReadStringArg(napi_env env, napi_callback_info info, size_t index, std::string &out)
{
    size_t argc = 8;
    napi_value args[8] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc) {
        out.clear();
        return false;
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, args[index], nullptr, 0, &len);
    out.assign(len, '\0');
    if (len > 0) {
        napi_get_value_string_utf8(env, args[index], &out[0], len + 1, &len);
        out.resize(len);
    }
    return true;
}

bool ReadIntArg(napi_env env, napi_callback_info info, size_t index, int64_t &out)
{
    size_t argc = 8;
    napi_value args[8] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc) {
        out = 0;
        return false;
    }
    napi_valuetype type;
    napi_typeof(env, args[index], &type);
    if (type == napi_number) {
        double d = 0;
        napi_get_value_double(env, args[index], &d);
        out = static_cast<int64_t>(d);
        return true;
    }
    if (type == napi_string) {
        std::string s;
        size_t len = 0;
        napi_get_value_string_utf8(env, args[index], nullptr, 0, &len);
        s.assign(len, '\0');
        if (len > 0) {
            napi_get_value_string_utf8(env, args[index], &s[0], len + 1, &len);
            s.resize(len);
        }
        try {
            out = std::stoll(s);
            return true;
        } catch (...) {
            out = 0;
            return false;
        }
    }
    out = 0;
    return false;
}

jellyfin::api::ItemsQuery ParseItemsQueryJson(const nlohmann::json &j)
{
    jellyfin::api::ItemsQuery query;
    if (!j.is_object()) {
        return query;
    }
    query.parentId = j.value("parentId", "");
    query.startIndex = j.value("startIndex", 0);
    query.limit = j.value("limit", 50);
    query.searchTerm = j.value("searchTerm", "");
    query.includeItemTypes = j.value("includeItemTypes", "");
    query.sortBy = j.value("sortBy", "");
    query.sortOrder = j.value("sortOrder", "");
    query.favoriteOnly = j.value("favoriteOnly", false);
    query.recursive = j.value("recursive", true);
    query.genreIds = j.value("genreIds", "");
    query.studioIds = j.value("studioIds", "");
    query.personIds = j.value("personIds", "");
    query.fields = j.value("fields", "");
    query.mediaTypes = j.value("mediaTypes", "");
    query.excludeItemTypes = j.value("excludeItemTypes", "");
    query.enableUserData = j.value("enableUserData", true);
    return query;
}

jellyfin::api::PlaybackInfoOptions ParsePlaybackOptionsJson(const nlohmann::json &j)
{
    jellyfin::api::PlaybackInfoOptions options;
    if (!j.is_object()) {
        return options;
    }
    options.audioStreamIndex = j.value("audioStreamIndex", -1);
    options.subtitleStreamIndex = j.value("subtitleStreamIndex", -1);
    options.maxStreamingBitrate = j.value("maxStreamingBitrate", 0);
    options.enableDirectPlay = j.value("enableDirectPlay", true);
    options.enableDirectStream = j.value("enableDirectStream", true);
    options.enableTranscoding = j.value("enableTranscoding", true);
    return options;
}

bool ReadJsonArg(napi_env env, napi_callback_info info, size_t index, nlohmann::json &out)
{
    std::string raw;
    if (!ReadStringArg(env, info, index, raw) || raw.empty()) {
        out = nlohmann::json::object();
        return false;
    }
    try {
        out = nlohmann::json::parse(raw);
        return true;
    } catch (...) {
        out = nlohmann::json::object();
        return false;
    }
}

bool ReadBoolArg(napi_env env, napi_callback_info info, size_t index, bool &out)
{
    size_t argc = 8;
    napi_value args[8] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc) {
        out = false;
        return false;
    }
    napi_valuetype type;
    napi_typeof(env, args[index], &type);
    if (type == napi_boolean) {
        bool b = false;
        napi_get_value_bool(env, args[index], &b);
        out = b;
        return true;
    }
    if (type == napi_number) {
        double d = 0;
        napi_get_value_double(env, args[index], &d);
        out = d != 0.0;
        return true;
    }
    out = false;
    return false;
}

napi_value GetVersion(napi_env env, napi_callback_info /*info*/)
{
    const std::string version = std::string(kNativeVersion) + ";" + jellyfin_core_version() + ";" +
                                jellyfin_player_version();
    return ToNapiString(env, version);
}

napi_value SetDeviceId(napi_env env, napi_callback_info info)
{
    std::string deviceId;
    if (!ReadStringArg(env, info, 0, deviceId) || deviceId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "deviceId required"));
    }
    auto &session = jellyfin::SessionManager::instance();
    session.setDeviceId(deviceId);
    return ToNapiJson(env, MakeResult(true, 0, "ok"));
}

napi_value ConfigureServer(napi_env env, napi_callback_info info)
{
    std::string baseUrl;
    if (!ReadStringArg(env, info, 0, baseUrl) || baseUrl.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "baseUrl required"));
    }
    const std::string normalized = jellyfin::NormalizeBaseUrl(baseUrl);
    if (normalized.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "Invalid baseUrl (expect http:// or https://)"));
    }
    return RunAsync(env, [normalized]() {
        auto &session = jellyfin::SessionManager::instance();
        session.configureServer(normalized);

        auto sys = jellyfin::api::getPublicSystemInfo(Api());
        if (sys.ok() && sys.data.is_object()) {
            if (sys.data.contains("ServerName") && sys.data["ServerName"].is_string()) {
                session.configureServer(normalized, sys.data["ServerName"].get<std::string>());
            }
        }

        nlohmann::json data = {
            {"baseUrl", session.baseUrl()},
            {"serverName", session.serverName()},
            {"deviceId", session.deviceId()},
            {"system", sys.ok() ? sys.data : nlohmann::json(nullptr)},
        };
        if (!sys.ok()) {
            return MakeResult(true, 200, "configured (system info unavailable)", data).dump();
        }
        return MakeResult(true, 200, "ok", data).dump();
    });
}

napi_value Login(napi_env env, napi_callback_info info)
{
    std::string username;
    std::string password;
    ReadStringArg(env, info, 0, username);
    ReadStringArg(env, info, 1, password);
    if (username.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "username required"));
    }

    return RunAsync(env, [username, password]() {
        auto result = jellyfin::api::authenticateByName(Api(), username, password);
        if (!result.ok()) {
            return FromApi(result).dump();
        }

        std::string token = JsonStringAny(result.data, {"AccessToken", "accessToken"});
        std::string userId;
        std::string userName;
        nlohmann::json userObj;
        if (result.data.contains("User") && result.data["User"].is_object()) {
            userObj = result.data["User"];
        } else if (result.data.contains("user") && result.data["user"].is_object()) {
            userObj = result.data["user"];
        }
        userId = JsonStringAny(userObj, {"Id", "id"});
        userName = JsonStringAny(userObj, {"Name", "name"});
        bool isAdmin = false;
        if (userObj.contains("Policy") && userObj["Policy"].is_object()) {
            isAdmin = userObj["Policy"].value("IsAdministrator", false);
        }
        if (token.empty() || userId.empty()) {
            std::string msg = result.error.message;
            if (msg.empty()) {
                msg = "Auth response missing token or user id";
            }
            const int code = result.error.statusCode > 0 ? result.error.statusCode : 502;
            return MakeResult(false, code, msg).dump();
        }

        jellyfin::SessionManager::instance().setAuth(token, userId, userName, isAdmin);
        nlohmann::json data = jellyfin::SessionManager::instance().toJson();
        // Token is needed for ArkTS persistence; do not print it to logs.
        return MakeResult(true, 200, "ok", data).dump();
    });
}

napi_value Logout(napi_env env, napi_callback_info /*info*/)
{
    Progress().reset();
    CurrentItemId.clear();
    jellyfin::SessionManager::instance().clearAuth();
    std::string err;
    jellyfin::player::PlayerEngine::instance().stop(err);
    return ToNapiJson(env, MakeResult(true, 200, "ok", nlohmann::json::object()));
}

napi_value RestoreSession(napi_env env, napi_callback_info info)
{
    std::string sessionJson;
    if (!ReadStringArg(env, info, 0, sessionJson) || sessionJson.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "sessionJson required"));
    }
    std::string error;
    if (!jellyfin::SessionManager::instance().fromJsonString(sessionJson, error)) {
        return ToNapiJson(env, MakeResult(false, 0, error));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok", jellyfin::SessionManager::instance().toJson()));
}

napi_value GetSession(napi_env env, napi_callback_info /*info*/)
{
    return ToNapiJson(env, MakeResult(true, 200, "ok", jellyfin::SessionManager::instance().toJson()));
}

napi_value GetHome(napi_env env, napi_callback_info /*info*/)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId]() {
        auto views = jellyfin::api::getUserViews(Api(), userId);
        auto resume = jellyfin::api::getResumeItems(Api(), userId, 0, 16);
        auto latest = jellyfin::api::getLatest(Api(), userId, 16);
        auto nextUp = jellyfin::api::getNextUp(Api(), userId, 0, 16);

        nlohmann::json data = {
            {"views", views.ok() ? views.data : nlohmann::json(nullptr)},
            {"Libraries", views.ok() ? views.data : nlohmann::json(nullptr)},
            {"resume", resume.ok() ? resume.data : nlohmann::json(nullptr)},
            {"Resume", resume.ok() ? resume.data : nlohmann::json(nullptr)},
            {"latest", latest.ok() ? latest.data : nlohmann::json(nullptr)},
            {"Latest", latest.ok() ? latest.data : nlohmann::json(nullptr)},
            {"nextUp", nextUp.ok() ? nextUp.data : nlohmann::json(nullptr)},
            {"NextUp", nextUp.ok() ? nextUp.data : nlohmann::json(nullptr)},
        };
        const bool anyOk = views.ok() || resume.ok() || latest.ok() || nextUp.ok();
        if (!anyOk) {
            return MakeResult(false, views.error.statusCode, views.error.message, data).dump();
        }
        return MakeResult(true, 200, "ok", data).dump();
    });
}

napi_value GetHomeSection(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string section;
    int64_t limit = 16;
    ReadStringArg(env, info, 0, section);
    ReadIntArg(env, info, 1, limit);
    if (limit <= 0) {
        limit = 16;
    }
    if (section != "views" && section != "libraries" && section != "resume" &&
        section != "latest" && section != "nextUp" && section != "nextup") {
        return ToNapiJson(env, MakeResult(false, 0, "unknown section"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [section, limit, userId]() {
        jellyfin::ApiResult result;
        if (section == "views" || section == "libraries") {
            result = jellyfin::api::getUserViews(Api(), userId);
        } else if (section == "resume") {
            result = jellyfin::api::getResumeItems(Api(), userId, 0, static_cast<int>(limit));
        } else if (section == "latest") {
            result = jellyfin::api::getLatest(Api(), userId, static_cast<int>(limit));
        } else {
            result = jellyfin::api::getNextUp(Api(), userId, 0, static_cast<int>(limit));
        }
        return FromApi(result).dump();
    });
}

napi_value GetBrowseItems(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string browseType;
    int64_t startIndex = 0;
    int64_t limit = 40;
    std::string parentId;
    ReadStringArg(env, info, 0, browseType);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    ReadStringArg(env, info, 3, parentId);
    if (limit <= 0) {
        limit = 40;
    }
    if (browseType != "resume" && browseType != "latest" && browseType != "nextUp" &&
        browseType != "nextup" && browseType != "favorites" && browseType != "favorite" &&
        browseType != "upcoming") {
        return ToNapiJson(env, MakeResult(false, 0, "unknown browse type"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [browseType, startIndex, limit, parentId, userId]() {
        jellyfin::ApiResult result;
        if (browseType == "resume") {
            result = jellyfin::api::getResumeItems(Api(), userId, static_cast<int>(startIndex),
                                                   static_cast<int>(limit));
        } else if (browseType == "latest") {
            jellyfin::api::ItemsQuery query;
            query.parentId = parentId;
            query.startIndex = static_cast<int>(startIndex);
            query.limit = static_cast<int>(limit);
            query.sortBy = "DateCreated";
            query.sortOrder = "Descending";
            query.includeItemTypes = "Movie,Series,Episode";
            result = jellyfin::api::queryItems(Api(), userId, query);
        } else if (browseType == "nextUp" || browseType == "nextup") {
            result = jellyfin::api::getNextUp(Api(), userId, static_cast<int>(startIndex),
                                              static_cast<int>(limit));
        } else if (browseType == "favorites" || browseType == "favorite") {
            jellyfin::api::ItemsQuery query;
            query.parentId = parentId;
            query.startIndex = static_cast<int>(startIndex);
            query.limit = static_cast<int>(limit);
            query.favoriteOnly = true;
            query.sortBy = "SortName";
            query.sortOrder = "Ascending";
            result = jellyfin::api::queryItems(Api(), userId, query);
        } else {
            result = jellyfin::api::getUpcomingEpisodes(Api(), userId, static_cast<int>(startIndex),
                                                        static_cast<int>(limit));
        }
        return FromApi(result).dump();
    });
}

napi_value QueryItems(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    nlohmann::json options;
    ReadJsonArg(env, info, 0, options);
    const auto query = ParseItemsQueryJson(options);
    const std::string userId = session.userId();
    return RunAsync(env, [query, userId]() {
        auto result = jellyfin::api::queryItems(Api(), userId, query);
        return FromApi(result).dump();
    });
}

napi_value GetGenres(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string parentId;
    int64_t startIndex = 0;
    int64_t limit = 100;
    ReadStringArg(env, info, 0, parentId);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, parentId, startIndex, limit]() {
        auto result = jellyfin::api::getGenres(Api(), userId, parentId,
                                               static_cast<int>(startIndex), static_cast<int>(limit));
        return FromApi(result).dump();
    });
}

napi_value GetStudios(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string parentId;
    int64_t startIndex = 0;
    int64_t limit = 100;
    ReadStringArg(env, info, 0, parentId);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, parentId, startIndex, limit]() {
        auto result = jellyfin::api::getStudios(Api(), userId, parentId,
                                                static_cast<int>(startIndex), static_cast<int>(limit));
        return FromApi(result).dump();
    });
}

napi_value GetSuggestions(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string parentId;
    int64_t limit = 20;
    ReadStringArg(env, info, 0, parentId);
    ReadIntArg(env, info, 1, limit);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, parentId, limit]() {
        auto result = jellyfin::api::getSuggestions(Api(), userId, parentId,
                                                    static_cast<int>(limit));
        return FromApi(result).dump();
    });
}

napi_value GetLibraryItems(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string parentId;
    int64_t startIndex = 0;
    int64_t limit = 50;
    ReadStringArg(env, info, 0, parentId);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    if (limit <= 0) {
        limit = 50;
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, parentId, startIndex, limit]() {
        auto result = jellyfin::api::getItems(Api(), userId, parentId,
                                              static_cast<int>(startIndex), static_cast<int>(limit));
        return FromApi(result).dump();
    });
}

napi_value Search(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string term;
    int64_t startIndex = 0;
    int64_t limit = 50;
    ReadStringArg(env, info, 0, term);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    if (term.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "search term required"));
    }
    if (limit <= 0) {
        limit = 50;
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, term, startIndex, limit]() {
        auto result =
            jellyfin::api::getItems(Api(), userId, {}, static_cast<int>(startIndex),
                                    static_cast<int>(limit), term);
        return FromApi(result).dump();
    });
}

napi_value GetItemDetail(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    if (!ReadStringArg(env, info, 0, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId]() {
        auto result = jellyfin::api::getItem(Api(), userId, itemId);
        if (!result.ok() || !result.data.is_object()) {
            return FromApi(result).dump();
        }
        const std::string type = result.data.value("Type", "");
        if (type == "Series") {
            auto seasons = jellyfin::api::getSeasons(Api(), userId, itemId);
            if (seasons.ok()) {
                result.data["Seasons"] = seasons.data;
            }
        }
        auto similar = jellyfin::api::getSimilar(Api(), userId, itemId, 12);
        if (similar.ok()) {
            result.data["Similar"] = similar.data;
        }
        return FromApi(result).dump();
    });
}

napi_value GetSeasonEpisodes(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string seriesId;
    std::string seasonId;
    ReadStringArg(env, info, 0, seriesId);
    ReadStringArg(env, info, 1, seasonId);
    if (seriesId.empty() || seasonId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "seriesId and seasonId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, seriesId, seasonId]() {
        auto result = jellyfin::api::getEpisodes(Api(), userId, seriesId, seasonId);
        return FromApi(result).dump();
    });
}

napi_value GetPlaybackInfo(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    if (!ReadStringArg(env, info, 0, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    nlohmann::json optionsJson;
    ReadJsonArg(env, info, 1, optionsJson);
    const auto options = ParsePlaybackOptionsJson(optionsJson);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId, options]() {
        auto result = jellyfin::api::postPlaybackInfo(Api(), itemId, userId, options);
        if (result.ok() && result.data.is_object()) {
            auto &session = jellyfin::SessionManager::instance();
            result.data["ResolvedPlayUrl"] = jellyfin::api::resolvePlayUrl(
                session.baseUrl(), session.accessToken(), result.data);
        }
        return FromApi(result).dump();
    });
}

napi_value ToggleFavorite(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    bool favorite = true;
    ReadStringArg(env, info, 0, itemId);
    ReadBoolArg(env, info, 1, favorite);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId, favorite]() {
        auto result = favorite ? jellyfin::api::markFavorite(Api(), userId, itemId)
                               : jellyfin::api::unmarkFavorite(Api(), userId, itemId);
        return FromApi(result).dump();
    });
}

napi_value TogglePlayed(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    bool played = true;
    ReadStringArg(env, info, 0, itemId);
    ReadBoolArg(env, info, 1, played);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId, played]() {
        auto result = played ? jellyfin::api::markPlayed(Api(), userId, itemId)
                             : jellyfin::api::markUnplayed(Api(), userId, itemId);
        return FromApi(result).dump();
    });
}

napi_value GetUserItemData(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    ReadStringArg(env, info, 0, itemId);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId]() {
        auto result = jellyfin::api::getUserItemData(Api(), userId, itemId);
        return FromApi(result).dump();
    });
}

napi_value GetUserById(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string userId;
    if (!ReadStringArg(env, info, 0, userId) || userId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "userId required"));
    }
    return RunAsync(env, [userId]() {
        return FromApi(jellyfin::api::getUserById(Api(), userId)).dump();
    });
}

napi_value UpdateUserConfiguration(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    nlohmann::json configuration;
    if (!ReadJsonArg(env, info, 0, configuration) || !configuration.is_object()) {
        return ToNapiJson(env, MakeResult(false, 0, "configurationJson required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, configuration]() {
        return FromApi(jellyfin::api::updateUserConfiguration(Api(), userId, configuration)).dump();
    });
}

napi_value SearchHints(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string query;
    int64_t limit = 12;
    if (!ReadStringArg(env, info, 0, query) || query.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "query required"));
    }
    ReadIntArg(env, info, 1, limit);
    if (limit <= 0 || limit > 50) {
        limit = 12;
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, query, limit]() {
        return FromApi(jellyfin::api::getSearchHints(Api(), userId, query, static_cast<int>(limit)))
            .dump();
    });
}

napi_value GetPlaylists(napi_env env, napi_callback_info /*info*/)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId]() {
        return FromApi(jellyfin::api::getPlaylists(Api(), userId)).dump();
    });
}

napi_value CreatePlaylist(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string name;
    std::string itemId;
    if (!ReadStringArg(env, info, 0, name) || name.empty() ||
        !ReadStringArg(env, info, 1, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "name and itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, name, itemId]() {
        return FromApi(jellyfin::api::createPlaylist(Api(), userId, name, itemId)).dump();
    });
}

napi_value AddToPlaylist(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string playlistId;
    std::string itemId;
    if (!ReadStringArg(env, info, 0, playlistId) || playlistId.empty() ||
        !ReadStringArg(env, info, 1, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "playlistId and itemId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, playlistId, itemId]() {
        return FromApi(jellyfin::api::addToPlaylist(Api(), playlistId, userId, itemId)).dump();
    });
}

nlohmann::json BuildProgressBody(const std::string &itemId, int64_t positionTicks, bool isPaused,
                                 bool stopped)
{
    nlohmann::json body = {
        {"ItemId", itemId},
        {"PositionTicks", positionTicks},
        {"IsPaused", isPaused},
        {"PlayMethod", "DirectStream"},
        {"CanSeek", true},
    };
    std::lock_guard<std::mutex> lock(g_playbackMutex);
    if (!CurrentMediaSourceId.empty()) {
        body["MediaSourceId"] = CurrentMediaSourceId;
    }
    if (!CurrentPlaySessionId.empty()) {
        body["PlaySessionId"] = CurrentPlaySessionId;
    }
    if (stopped) {
        body["IsPaused"] = false;
    }
    return body;
}

napi_value ReportPlaybackProgress(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    int64_t positionTicks = 0;
    bool isPaused = false;
    ReadStringArg(env, info, 0, itemId);
    ReadIntArg(env, info, 1, positionTicks);
    ReadBoolArg(env, info, 2, isPaused);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }

    return RunAsync(env, [itemId, positionTicks, isPaused]() {
        if (!Progress().shouldReport(isPaused, false)) {
            return MakeResult(true, 200, "throttled", nlohmann::json{{"sent", false}}).dump();
        }

        auto body = BuildProgressBody(itemId, positionTicks, isPaused, false);
        auto result = jellyfin::api::reportPlaybackProgress(Api(), body);
        if (result.ok()) {
            Progress().markReported(isPaused);
        }
        nlohmann::json data = result.data.is_null() ? nlohmann::json::object() : result.data;
        data["sent"] = result.ok();
        return MakeResult(result.ok(), result.error.statusCode,
                          result.ok() ? "ok" : result.error.message, data).dump();
    });
}

napi_value ReportPlaybackStopped(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    int64_t positionTicks = 0;
    ReadStringArg(env, info, 0, itemId);
    ReadIntArg(env, info, 1, positionTicks);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    return RunAsync(env, [itemId, positionTicks]() {
        auto body = BuildProgressBody(itemId, positionTicks, false, true);
        auto result = jellyfin::api::reportPlaybackStopped(Api(), body);
        Progress().reset();
        return FromApi(result).dump();
    });
}

napi_value PlayerOpen(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    if (!ReadStringArg(env, info, 0, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }

    nlohmann::json optionsJson;
    ReadJsonArg(env, info, 1, optionsJson);
    const auto options = ParsePlaybackOptionsJson(optionsJson);

    const std::string userId = session.userId();
    return RunAsync(env, [userId, itemId, options]() {
        auto playback = jellyfin::api::postPlaybackInfo(Api(), itemId, userId, options);
        if (!playback.ok()) {
            return FromApi(playback).dump();
        }
        if (playback.data.is_object() && !playback.data.contains("ItemId")) {
            playback.data["ItemId"] = itemId;
        }

        auto &session = jellyfin::SessionManager::instance();
        jellyfin::player::PlaybackSession pbSession;
        std::string error;
        if (!jellyfin::player::ResolvePlaybackSession(playback.data, session.baseUrl(),
                                                      session.accessToken(), pbSession, error)) {
            return MakeResult(false, 0, error).dump();
        }
        if (pbSession.itemId.empty()) {
            pbSession.itemId = itemId;
        }

        {
            std::lock_guard<std::mutex> lock(g_playbackMutex);
            CurrentItemId = pbSession.itemId;
            CurrentPlaySessionId = pbSession.playSessionId;
            CurrentMediaSourceId = pbSession.mediaSourceId;
        }
        Progress().reset();

        nlohmann::json startBody = BuildProgressBody(pbSession.itemId, 0, false, false);
        startBody["CanSeek"] = true;
        (void)jellyfin::api::reportPlaybackStart(Api(), startBody);

        if (!jellyfin::player::PlayerEngine::instance().prepareExternalRenderer(pbSession, error)) {
            return MakeResult(false, 0, error).dump();
        }

        // ArkTS owns the real AVPlayer decoder and video surface. Native only
        // resolves the session and reports Jellyfin playback state.
        nlohmann::json data = jellyfin::player::PlayerEngine::instance().toJson();
        data["playbackInfo"] = playback.data;
        return MakeResult(true, 200, "ok", data).dump();
    });
}

napi_value PlayerPlay(napi_env env, napi_callback_info /*info*/)
{
    std::string error;
    if (!jellyfin::player::PlayerEngine::instance().play(error)) {
        return ToNapiJson(env, MakeResult(false, 0, error));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::player::PlayerEngine::instance().toJson()));
}

napi_value PlayerPause(napi_env env, napi_callback_info /*info*/)
{
    std::string error;
    if (!jellyfin::player::PlayerEngine::instance().pause(error)) {
        return ToNapiJson(env, MakeResult(false, 0, error));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::player::PlayerEngine::instance().toJson()));
}

napi_value PlayerSeek(napi_env env, napi_callback_info info)
{
    int64_t positionTicks = 0;
    ReadIntArg(env, info, 0, positionTicks);
    std::string error;
    if (!jellyfin::player::PlayerEngine::instance().seek(positionTicks, error)) {
        return ToNapiJson(env, MakeResult(false, 0, error));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::player::PlayerEngine::instance().toJson()));
}

napi_value PlayerStop(napi_env env, napi_callback_info /*info*/)
{
    std::string error;
    (void)jellyfin::player::PlayerEngine::instance().stop(error);
    Progress().reset();
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::player::PlayerEngine::instance().toJson()));
}

napi_value PlayerGetState(napi_env env, napi_callback_info /*info*/)
{
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::player::PlayerEngine::instance().toJson()));
}

nlohmann::json RequireAdmin()
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return MakeResult(false, 401, "Not authenticated");
    }
    if (!session.isAdmin()) {
        return MakeResult(false, 403, "Administrator permission required");
    }
    return nlohmann::json();
}

napi_value AdminListUsers(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(jellyfin::api::getUsers(Api())).dump(); });
}

napi_value AdminListDevices(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(Api().getJson("/Devices")).dump(); });
}

napi_value AdminListTasks(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(Api().getJson("/ScheduledTasks")).dump(); });
}

napi_value AdminGetSystemInfo(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(Api().getJson("/System/Info")).dump(); });
}

bool IsAllowedAdminPath(const std::string &path)
{
    const size_t queryStart = path.find('?');
    const std::string route = queryStart == std::string::npos ? path : path.substr(0, queryStart);
    const std::string exact[] = {
        "/System/Info", "/System/Logs", "/System/ActivityLog/Entries",
        "/System/Configuration", "/System/Configuration/branding",
        "/System/Configuration/network", "/System/Configuration/encoding",
        "/System/Configuration/metadata", "/System/Configuration/library",
        "/System/Configuration/nfo", "/System/Configuration/trickplay",
        "/Library/VirtualFolders", "/Library/MediaFolders", "/ScheduledTasks",
        "/Auth/Keys", "/Devices", "/Packages", "/Users/New", "/Users/Configuration"
    };
    for (const std::string &candidate : exact) {
        if (route == candidate) {
            return true;
        }
    }

    const std::string simplePrefixes[] = {
        "/ScheduledTasks/Running/", "/Packages/Installed/", "/Packages/Installing/",
        "/Auth/Keys/"
    };
    for (const std::string &prefix : simplePrefixes) {
        if (route.rfind(prefix, 0) != 0) {
            continue;
        }
        const std::string tail = route.substr(prefix.size());
        if (tail.empty() || tail.find('/') != std::string::npos || tail == "." || tail == "..") {
            return false;
        }
        return true;
    }

    const std::string userPrefix = "/Users/";
    if (route.rfind(userPrefix, 0) == 0) {
        const std::string tail = route.substr(userPrefix.size());
        const size_t slash = tail.find('/');
        if (slash == std::string::npos) {
            return !tail.empty() && tail != "." && tail != "..";
        }
        const std::string userId = tail.substr(0, slash);
        const std::string operation = tail.substr(slash + 1);
        return !userId.empty() && userId != "." && userId != ".." &&
            (operation == "Policy" || operation == "Configuration");
    }

    return false;
}

bool ReadSafeAdminPath(napi_env env, napi_callback_info info, std::string &path)
{
    if (!ReadStringArg(env, info, 0, path) || path.empty()) {
        return false;
    }
    if (path[0] != '/') {
        path = "/" + path;
    }
    std::string encodedLower = path;
    for (char &c : encodedLower) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    if (path.find("://") != std::string::npos || path.find('\\') != std::string::npos ||
        path.find("../") != std::string::npos || path.find("/..") != std::string::npos ||
        encodedLower.find("%2e") != std::string::npos || encodedLower.find("%2f") != std::string::npos) {
        return false;
    }
    return IsAllowedAdminPath(path);
}

napi_value AdminGenericGet(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string path;
    if (!ReadSafeAdminPath(env, info, path)) {
        return ToNapiJson(env, MakeResult(false, 400, "Invalid API path"));
    }
    return RunAsync(env, [path]() { return FromApi(Api().getJson(path)).dump(); });
}

napi_value AdminGenericPost(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string path;
    nlohmann::json body;
    if (!ReadSafeAdminPath(env, info, path) || !ReadJsonArg(env, info, 1, body)) {
        return ToNapiJson(env, MakeResult(false, 400, "Valid path and JSON body required"));
    }
    return RunAsync(env, [path, body]() { return FromApi(Api().postJson(path, body)).dump(); });
}

napi_value AdminGenericPostNoBody(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string path;
    if (!ReadSafeAdminPath(env, info, path)) {
        return ToNapiJson(env, MakeResult(false, 400, "Invalid API path"));
    }
    return RunAsync(env, [path]() {
        return FromApi(Api().postJson(path, nlohmann::json(nullptr))).dump();
    });
}

napi_value AdminGenericDelete(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string path;
    if (!ReadSafeAdminPath(env, info, path)) {
        return ToNapiJson(env, MakeResult(false, 400, "Invalid API path"));
    }
    return RunAsync(env, [path]() { return FromApi(Api().deleteJson(path)).dump(); });
}

napi_value SetPreference(napi_env env, napi_callback_info info)
{
    std::string key;
    std::string valueJson;
    ReadStringArg(env, info, 0, key);
    ReadStringArg(env, info, 1, valueJson);
    if (key.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "key required"));
    }
    nlohmann::json value = nullptr;
    if (!valueJson.empty()) {
        try {
            value = nlohmann::json::parse(valueJson);
        } catch (...) {
            value = valueJson;
        }
    }
    jellyfin::SessionManager::instance().setPreference(key, value);
    return ToNapiJson(env,
                      MakeResult(true, 200, "ok", jellyfin::SessionManager::instance().toJson()));
}

napi_value GetPreferences(napi_env env, napi_callback_info /*info*/)
{
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                      jellyfin::SessionManager::instance().preferences()));
}

napi_value GetImageUrl(napi_env env, napi_callback_info info)
{
    std::string itemId;
    std::string imageType;
    std::string tag;
    int64_t maxWidth = 0;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, imageType);
    ReadIntArg(env, info, 2, maxWidth);
    ReadStringArg(env, info, 3, tag);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    if (imageType.empty()) {
        imageType = "Primary";
    }
    auto &session = jellyfin::SessionManager::instance();
    const std::string url =
        jellyfin::BuildImageUrl(session.baseUrl(), itemId, imageType, static_cast<int>(maxWidth),
                                tag, session.accessToken());
    if (url.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "Unable to build image url"));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok", nlohmann::json{{"url", url}}));
}

napi_value SetImageCacheDir(napi_env env, napi_callback_info info)
{
    std::string dir;
    ReadStringArg(env, info, 0, dir);
    if (dir.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "dir required"));
    }
    jellyfin::ImageCache::instance().setCacheDirectory(dir);
    return ToNapiJson(env, MakeResult(true, 200, "ok", nlohmann::json{{"dir", dir}}));
}

napi_value LoadImage(napi_env env, napi_callback_info info)
{
    std::string url;
    ReadStringArg(env, info, 0, url);
    if (url.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "url required"));
    }
    return RunAsync(env, [url]() {
        std::string error;
        const std::string path = jellyfin::ImageCache::instance().getOrDownload(url, error);
        if (path.empty()) {
            return MakeResult(false, 0, error.empty() ? "image download failed" : error).dump();
        }
        return MakeResult(true, 200, "ok", nlohmann::json{{"path", path}}).dump();
    });
}

napi_value ClearImageCache(napi_env env, napi_callback_info /*info*/)
{
    jellyfin::ImageCache::instance().clear();
    return ToNapiJson(env, MakeResult(true, 200, "ok", nlohmann::json::object()));
}

} // namespace

napi_value jellyfin_napi_init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"configureServer", nullptr, ConfigureServer, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setDeviceId", nullptr, SetDeviceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"login", nullptr, Login, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logout", nullptr, Logout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"restoreSession", nullptr, RestoreSession, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getSession", nullptr, GetSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getHome", nullptr, GetHome, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getHomeSection", nullptr, GetHomeSection, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBrowseItems", nullptr, GetBrowseItems, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryItems", nullptr, QueryItems, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGenres", nullptr, GetGenres, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStudios", nullptr, GetStudios, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSuggestions", nullptr, GetSuggestions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLibraryItems", nullptr, GetLibraryItems, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"search", nullptr, Search, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getItemDetail", nullptr, GetItemDetail, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSeasonEpisodes", nullptr, GetSeasonEpisodes, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getPlaybackInfo", nullptr, GetPlaybackInfo, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"toggleFavorite", nullptr, ToggleFavorite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"togglePlayed", nullptr, TogglePlayed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getUserItemData", nullptr, GetUserItemData, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getUserById", nullptr, GetUserById, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateUserConfiguration", nullptr, UpdateUserConfiguration, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"searchHints", nullptr, SearchHints, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPlaylists", nullptr, GetPlaylists, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createPlaylist", nullptr, CreatePlaylist, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"addToPlaylist", nullptr, AddToPlaylist, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"reportPlaybackProgress", nullptr, ReportPlaybackProgress, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"reportPlaybackStopped", nullptr, ReportPlaybackStopped, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"playerOpen", nullptr, PlayerOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerPlay", nullptr, PlayerPlay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerPause", nullptr, PlayerPause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerSeek", nullptr, PlayerSeek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerStop", nullptr, PlayerStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerGetState", nullptr, PlayerGetState, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminListUsers", nullptr, AdminListUsers, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminListDevices", nullptr, AdminListDevices, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminListTasks", nullptr, AdminListTasks, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGetSystemInfo", nullptr, AdminGetSystemInfo, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericGet", nullptr, AdminGenericGet, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericPost", nullptr, AdminGenericPost, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericPostNoBody", nullptr, AdminGenericPostNoBody, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"adminGenericDelete", nullptr, AdminGenericDelete, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setPreference", nullptr, SetPreference, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPreferences", nullptr, GetPreferences, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getImageUrl", nullptr, GetImageUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setImageCacheDir", nullptr, SetImageCacheDir, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"loadImage", nullptr, LoadImage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearImageCache", nullptr, ClearImageCache, nullptr, nullptr, nullptr, napi_default,
         nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
