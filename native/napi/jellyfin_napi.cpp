#include "jellyfin_napi.h"

#include "api/account_api.h"
#include "api/catalog_api.h"
#include "api/library_admin_api.h"
#include "api/media_api.h"
#include "api/playback_api.h"
#include "api/playlist_api.h"
#include "api/system_api.h"
#include "api/user_items_api.h"
#include "api_client.h"
#include "app_version.h"
#include "engine.h"
#include "http_client.h"
#include "http_tls.h"
#include "image_cache.h"
#include "image_url.h"
#include "playback_policy.h"
#include "session.h"
#include "subtitle_url.h"
#include "url_util.h"
#include "version.h"

// Player version header shares the name version.h; include via relative path.
#include "../feature/player/version.h"
// ── feature/player（可移植的播放能力）──────────────────────────────────
// 取流由本工程注入：CDN/鉴权/https 都走 core 的 HttpClient
#include "../feature/player/range_fetcher.h"
// FFmpeg 软解码器（未链接 FFmpeg 时其 available() 返回 false，probe 会如实报错）
#include "../feature/player/ffmpeg_decoder.h"
// 流式软解会话（播放用：Range 分页取流 + 逐帧 RGBA 输出）
#include "../feature/player/player_log.h"
#include "../feature/player/soft_decode_session.h"
// EGL/GLES 渲染（把软解帧直接画进 XComponent surface）
#include "../feature/player/egl_renderer.h"
// 官方 XComponent 原生渲染桥（OH_NativeXComponent 回调提供 window）
#include "../feature/player/xcomponent_bridge.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <functional>
#include <mutex>
#include <string>
#include <sys/resource.h>
#include <vector>

#include <hilog/log.h>
#include <nlohmann/json.hpp>

namespace {

// 版本号与 app.json5 的 versionName 同源（CMake 注入 JELLYFIN_APP_VERSION），不再单独写死
constexpr const char *kNativeVersion = JELLYFIN_APP_VERSION "-native";


/** 软解诊断日志（定义在本文件后部；取流计时等早于此处的代码需要前置声明） */
void SoftLog(const std::string &message);

/**
 * 向 feature/player 注入取流实现（本工程用 core 的 HttpClient，支持 https 与 Jellyfin 鉴权）。
 * feature/player 自身不依赖任何 HTTP 实现，换工程时只需替换这里的注入。
 */
void EnsureRangeFetcher()
{
    static std::once_flag once;
    std::call_once(once, []() {
        // feature/player 的日志注入：软解内部的耗时诊断（慢帧分段耗时等）接到 hilog 上。
        // 该模块本身不依赖 hilog（设计上要能整目录移植），所以由宿主在这里接线。
        jellyfin::player::SetPlayerLogFn([](const char *message) {
            if (message != nullptr) {
                SoftLog(std::string("player: ") + message);
            }
        });
        jellyfin::player::SetRangeFetcher([](const std::string &url, int64_t start, int64_t end) {
            jellyfin::player::RangeResponse out;
            jellyfin::HttpClient http;
            http.setReadTimeoutSec(60);
            http.setConnectTimeoutSec(10);
            jellyfin::HttpHeaders headers;
            if (end >= start) {
                headers["Range"] = "bytes=" + std::to_string(start) + "-" + std::to_string(end);
            }
            const auto t0 = std::chrono::steady_clock::now();
            const jellyfin::HttpResponse resp = http.get(url, headers);
            const int64_t ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                   std::chrono::steady_clock::now() - t0)
                                   .count();
            // 慢取流必须留痕：软解"卡住不动"时，第一件要分清的事就是
            // "卡在网络上"还是"卡在解码上"。设备实测过一次 20 秒级停滞（看门狗判卡死），
            // 没有这条日志就只能靠猜。>500ms 一律记录；前 3 次也记录（起播阶段的口径）。
            static std::atomic<int> firstCalls{0};
            const int callIndex = firstCalls.fetch_add(1);
            if (ms > 500 || callIndex < 3) {
                SoftLog("rangeFetch start=" + std::to_string(start) + " end=" + std::to_string(end)
                        + " status=" + std::to_string(resp.status)
                        + " bytes=" + std::to_string(resp.body.size())
                        + " ms=" + std::to_string(ms)
                        + (resp.error.empty() ? std::string() : (" err=" + resp.error)));
            }
            out.status = resp.status;
            out.body = resp.body;
            out.error = resp.error;
            return out;
        });
    });
}

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
/**
 * 当前这次播放的**实际播放方式**（`DirectPlay` / `DirectStream` / `Transcode`）。
 *
 * 为什么必须记录：进度上报里的 `PlayMethod` 曾经**写死 `DirectStream`**，
 * 于是"服务端转码播放"在服务端那边看不出是转码 —— 设备实测：客户端日志是
 * `playerOpen method=Transcode hls=1`，而 `/Sessions` 仍报 `DirectStream`、
 * `TranscodingInfo` 为空。Jellyfin 的播放方式由客户端上报，写死等于把"转码"
 * 瞒着服务端：仪表盘的转码统计、码率限速与"是否在转码"的判断都会失真。
 */
std::string CurrentPlayMethod;
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
    query.filters = j.value("filters", "");
    query.years = j.value("years", "");
    query.officialRatings = j.value("officialRatings", "");
    query.minOfficialRating = j.value("minOfficialRating", "");
    query.tags = j.value("tags", "");
    query.videoTypes = j.value("videoTypes", "");
    query.isHd = j.value("isHd", false);
    query.is4k = j.value("is4k", false);
    query.hasSubtitles = j.value("hasSubtitles", false);
    query.enableTotalRecordCount = j.value("enableTotalRecordCount", true);
    // 本地随机抽样池（0 = 关闭，走服务端原生 Random 排序）。
    // 为什么由客户端抽样：服务端 RandomComparer 的比较器不自洽，会随机抛 400
    // （见 `ItemsQuery::randomSamplePoolSize` 的说明）。
    query.randomSamplePoolSize = j.value("randomSamplePoolSize", 0);
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
    // 是否带 DeviceProfile（默认带，见 api::PlaybackInfoOptions 的说明）。
    // 宿主可在"用户明确要求强制直连"等场景置 false。
    options.includeDeviceProfile = j.value("includeDeviceProfile", true);
    return options;
}

/**
 * 请求 PlaybackInfo，并在**服务端给不出任何可用地址**时去掉 DeviceProfile 重试一次。
 *
 * 为什么需要这条保底路径：带上 DeviceProfile 后服务端按"客户端能直接播什么"判断；
 * 若它既不能转码（没装/没开 ffmpeg）又不认为能直接播放，响应里就不会有任何可用 URL。
 * 那时直接报错的话，用户看到的是"以前能放（慢），现在放不了"。重试一次不带 DeviceProfile
 * 即可退回改造前的行为：直连 + 本机软解（AV1 由 dav1d 解，慢但能看）。
 *
 * @param usedFallback 输出：是否走了保底重试（宿主与日志据此留痕）
 */
jellyfin::ApiResult PostPlaybackInfoWithProfileFallback(
    const std::string &itemId, const std::string &userId,
    const jellyfin::api::PlaybackInfoOptions &options, bool &usedFallback)
{
    usedFallback = false;
    auto result = jellyfin::api::postPlaybackInfo(Api(), itemId, userId, options);
    if (!result.ok() || !options.includeDeviceProfile) {
        return result;
    }
    if (jellyfin::api::playbackInfoHasPlayableUrl(result.data)) {
        return result;
    }
    jellyfin::api::PlaybackInfoOptions direct = options;
    direct.includeDeviceProfile = false;
    auto retry = jellyfin::api::postPlaybackInfo(Api(), itemId, userId, direct);
    if (retry.ok() && retry.data.is_object()) {
        retry.data["DeviceProfileFallback"] = true;
        usedFallback = true;
        return retry;
    }
    return result;
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
    {
        std::lock_guard<std::mutex> lock(g_playbackMutex);
        CurrentPlayMethod.clear();
    }
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
    std::string parentId;
    std::string includeItemTypes;
    int64_t startIndex = 0;
    int64_t limit = 50;
    ReadStringArg(env, info, 0, term);
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    // 可选参数：限定某个媒体库（库内搜索）与条目类型（电影/剧集/单集/音乐/合集…）
    ReadStringArg(env, info, 3, parentId);
    ReadStringArg(env, info, 4, includeItemTypes);
    if (term.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "search term required"));
    }
    if (limit <= 0) {
        limit = 50;
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, term, startIndex, limit, parentId, includeItemTypes]() {
        // 走 queryItems（而不是 getItems）以便：限定 ParentId、按类型筛选、并请求总数
        jellyfin::api::ItemsQuery query;
        query.parentId = parentId;
        query.startIndex = static_cast<int>(startIndex);
        query.limit = static_cast<int>(limit);
        query.searchTerm = term;
        query.includeItemTypes = includeItemTypes;
        query.enableTotalRecordCount = true;
        auto result = jellyfin::api::queryItems(Api(), userId, query);
        return FromApi(result).dump();
    });
}

/**
 * 当前用户的媒体库视图列表（`GET /Users/{userId}/Views`）。
 * 与 `/Library/VirtualFolders` 的区别：这个端点普通用户也能调，
 * 而且返回的 `Id` 正是用户配置里 `OrderedViews` / `MyMediaExcludes` /
 * `LatestItemsExcludes` / `GroupedFolders` 引用的值。
 */
napi_value GetUserViews(napi_env env, napi_callback_info /*info*/)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId]() {
        return FromApi(jellyfin::api::getUserViews(Api(), userId)).dump();
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

napi_value GetNextUpForSeries(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string seriesId;
    ReadStringArg(env, info, 0, seriesId);
    if (seriesId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "seriesId required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, seriesId]() {
        auto result = jellyfin::api::getNextUpForSeries(Api(), userId, seriesId);
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
        bool fallback = false;
        auto result = PostPlaybackInfoWithProfileFallback(itemId, userId, options, fallback);
        if (result.ok() && result.data.is_object()) {
            auto &session = jellyfin::SessionManager::instance();
            result.data["ResolvedPlayUrl"] = jellyfin::api::resolvePlayUrl(
                session.baseUrl(), session.accessToken(), result.data);
            if (fallback) {
                result.data["DeviceProfileFallback"] = true;
            }
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

/**
 * 只改若干用户配置字段：core 里做「GET 当前配置 → 合并 → POST 完整配置」。
 *
 * 之前这里是把入参当完整配置直接 POST 的，配上一个写错的端点
 * （`/Users/Configuration?userId=` —— 正确路由是 `/Users/{userId}/Configuration`），
 * 结果所有"用户设置"开关都保存不了；而且即使端点写对，只传部分字段也会让服务端
 * 把没带的字段重置成默认值（见 account_api.h 的说明）。
 */
napi_value PatchUserConfiguration(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    nlohmann::json patch;
    if (!ReadJsonArg(env, info, 0, patch) || !patch.is_object()) {
        return ToNapiJson(env, MakeResult(false, 0, "configuration patch required"));
    }
    const std::string userId = session.userId();
    return RunAsync(env, [userId, patch]() {
        return FromApi(jellyfin::api::patchUserConfiguration(Api(), userId, patch)).dump();
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
    // 可选：限定媒体库（库内搜索建议）与条目类型
    std::string parentId;
    std::string includeItemTypes;
    ReadStringArg(env, info, 2, parentId);
    ReadStringArg(env, info, 3, includeItemTypes);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, query, limit, parentId, includeItemTypes]() {
        return FromApi(jellyfin::api::getSearchHints(Api(), userId, query, static_cast<int>(limit),
                                                     parentId, includeItemTypes))
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
    std::string mediaType;
    if (!ReadStringArg(env, info, 0, name) || name.empty() ||
        !ReadStringArg(env, info, 1, itemId) || itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "name and itemId required"));
    }
    // 第 3 个参数可选：媒体类型（默认 Video）。音乐曲目应传 Audio，否则服务端把它归到视频列表。
    ReadStringArg(env, info, 2, mediaType);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, name, itemId, mediaType]() {
        return FromApi(jellyfin::api::createPlaylist(Api(), userId, name, itemId, mediaType)).dump();
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

napi_value GetPlaylistItems(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string playlistId;
    int64_t startIndex = 0;
    int64_t limit = 200;
    if (!ReadStringArg(env, info, 0, playlistId) || playlistId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "playlistId required"));
    }
    ReadIntArg(env, info, 1, startIndex);
    ReadIntArg(env, info, 2, limit);
    const std::string userId = session.userId();
    return RunAsync(env, [userId, playlistId, startIndex, limit]() {
        // userId 必填（缺省时服务端 400），这里显式传
        return FromApi(jellyfin::api::getPlaylistItems(Api(), playlistId, userId,
                                                       static_cast<int>(startIndex),
                                                       static_cast<int>(limit)))
            .dump();
    });
}

napi_value RemoveFromPlaylist(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string playlistId;
    std::string entryIds;
    if (!ReadStringArg(env, info, 0, playlistId) || playlistId.empty() ||
        !ReadStringArg(env, info, 1, entryIds) || entryIds.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "playlistId and entryIds required"));
    }
    return RunAsync(env, [playlistId, entryIds]() {
        return FromApi(jellyfin::api::removeFromPlaylist(Api(), playlistId, entryIds)).dump();
    });
}

napi_value MovePlaylistItem(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string playlistId;
    std::string entryId;
    int64_t newIndex = -1;
    if (!ReadStringArg(env, info, 0, playlistId) || playlistId.empty() ||
        !ReadStringArg(env, info, 1, entryId) || entryId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "playlistId and entryId required"));
    }
    ReadIntArg(env, info, 2, newIndex);
    if (newIndex < 0) {
        return ToNapiJson(env, MakeResult(false, 0, "newIndex required"));
    }
    return RunAsync(env, [playlistId, entryId, newIndex]() {
        return FromApi(jellyfin::api::movePlaylistItem(Api(), playlistId, entryId,
                                                       static_cast<int>(newIndex)))
            .dump();
    });
}

napi_value DeletePlaylist(napi_env env, napi_callback_info info)
{
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string playlistId;
    if (!ReadStringArg(env, info, 0, playlistId) || playlistId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "playlistId required"));
    }
    return RunAsync(env, [playlistId]() {
        return FromApi(jellyfin::api::deletePlaylist(Api(), playlistId)).dump();
    });
}

nlohmann::json BuildProgressBody(const std::string &itemId, int64_t positionTicks, bool isPaused,
                                 bool stopped)
{
    nlohmann::json body = {
        {"ItemId", itemId},
        {"PositionTicks", positionTicks},
        {"IsPaused", isPaused},
        {"CanSeek", true},
    };
    std::lock_guard<std::mutex> lock(g_playbackMutex);
    // 播放方式按**实际**情况上报（见 CurrentPlayMethod 的说明）；未知时按 DirectStream
    // （本工程的直连串流是最常见形态，也是改造前的上报值）。
    body["PlayMethod"] = CurrentPlayMethod.empty() ? "DirectStream" : CurrentPlayMethod;
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

/**
 * 软解播放会话（流式）：open / nextFrame / close / status。
 *
 * 用途：系统硬解不支持的编码（如模拟器上的 HEVC）用 FFmpeg 软解逐帧出图，
 * 由 ArkTS 定时器拉帧并渲染（后续可替换为 EGL 直渲以提升帧率）。
 */
/**
 * 软解会话单例。
 *
 * ⚠ 必须是 **shared_ptr**（而不是 unique_ptr）—— 这是设备上实测到的崩溃（cppcrash）根因：
 * 逐帧拉取跑在 libuv 工作线程上（`softPlayNextFrame` 是 `RunAsync`），而"停止软解"跑在
 * UI 线程：宿主看门狗（20s 没拉回一帧）或退出播放页时会调 `softPlayClose`。若那里直接
 * `unique_ptr::reset()`，正在飞的那次 `nextFrameRgba()` 就会踩到已经被析构的会话对象 ——
 * 实测 faultlog 栈为 `RangeCache::read → fetchIntoLockedRange → std::mutex::lock`
 * 落在已释放内存上（SIGSEGV，进程直接挂掉，用户看到"播放中应用消失"）。
 * 改成 shared_ptr 后：工作线程持有一份引用，对象活到那次调用结束；关闭只是"不再有新任务"。
 */
struct SoftSessionHolder {
    std::mutex mutex;
    std::shared_ptr<jellyfin::player::SoftDecodeSession> session;
};

SoftSessionHolder &SoftSessionStore()
{
    static SoftSessionHolder holder;
    return holder;
}

/** 取当前会话的一份引用（可能为 nullptr）；**异步任务必须先取一份再使用** */
std::shared_ptr<jellyfin::player::SoftDecodeSession> SoftSession()
{
    SoftSessionHolder &store = SoftSessionStore();
    std::lock_guard<std::mutex> lock(store.mutex);
    return store.session;
}

/** 替换当前会话（旧的交给持有它的异步任务用完再析构） */
void SetSoftSession(std::shared_ptr<jellyfin::player::SoftDecodeSession> session)
{
    SoftSessionHolder &store = SoftSessionStore();
    std::lock_guard<std::mutex> lock(store.mutex);
    store.session = std::move(session);
}

/** 软解渲染器（EGL）：与软解会话配对，把解码帧直接渲染到 XComponent surface */
jellyfin::player::EglRenderer &SoftRenderer()
{
    static jellyfin::player::EglRenderer renderer;
    return renderer;
}

/** 最近一帧的 RGBA（回读/导出用），保留引用避免立即释放 */
std::vector<uint8_t> &SoftLastFrame()
{
    static std::vector<uint8_t> frame;
    return frame;
}

/** 最近一帧的宽高（导出时需要，帧缓冲是 surface 尺寸、与解码尺寸不同） */
int &SoftLastFrameWidth()
{
    static int width = 0;
    return width;
}

int &SoftLastFrameHeight()
{
    static int height = 0;
    return height;
}

std::mutex &SoftLastFrameMutex()
{
    static std::mutex mutex;
    return mutex;
}

/**
 * 把 RGBA 编码成 PNG 落盘（glReadPixels 回读结果的验证出口）。
 * 不依赖系统截图是否包含 surface 内容。
 */
#if defined(JELLYFIN_HAS_FFMPEG)
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}
#endif

bool WriteRgbaPng(const std::vector<uint8_t> &rgba, int width, int height, const std::string &path,
                  std::string &error)
{
#if defined(JELLYFIN_HAS_FFMPEG)
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_PNG);
    if (codec == nullptr) {
        error = "本构建未启用 PNG 编码器";
        return false;
    }
    AVCodecContext *enc = avcodec_alloc_context3(codec);
    enc->width = width;
    enc->height = height;
    enc->pix_fmt = AV_PIX_FMT_RGBA;
    enc->time_base = AVRational{1, 25};
    if (avcodec_open2(enc, codec, nullptr) < 0) {
        avcodec_free_context(&enc);
        error = "打开 PNG 编码器失败";
        return false;
    }
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_PIX_FMT_RGBA;
    frame->width = width;
    frame->height = height;
    if (av_frame_get_buffer(frame, 32) < 0) {
        av_frame_free(&frame);
        avcodec_free_context(&enc);
        error = "分配帧缓冲失败";
        return false;
    }
    const size_t stride = static_cast<size_t>(width) * 4u;
    for (int y = 0; y < height; ++y) {
        std::memcpy(frame->data[0] + static_cast<size_t>(y) * frame->linesize[0],
                    rgba.data() + static_cast<size_t>(y) * stride, stride);
    }
    bool ok = false;
    if (avcodec_send_frame(enc, frame) < 0) {
        error = "提交编码帧失败";
    } else {
        AVPacket *pkt = av_packet_alloc();
        const int rc = avcodec_receive_packet(enc, pkt);
        if (rc < 0) {
            error = "PNG 编码失败";
        } else {
            FILE *fp = std::fopen(path.c_str(), "wb");
            if (fp == nullptr) {
                error = "无法写入 " + path;
            } else {
                ok = std::fwrite(pkt->data, 1, static_cast<size_t>(pkt->size), fp) ==
                     static_cast<size_t>(pkt->size);
                std::fclose(fp);
                if (!ok) {
                    error = "PNG 写盘不完整";
                }
            }
        }
        av_packet_free(&pkt);
    }
    av_frame_free(&frame);
    avcodec_free_context(&enc);
    return ok;
#else
    (void)rgba;
    (void)width;
    (void)height;
    (void)path;
    error = "本构建未链接 FFmpeg";
    return false;
#endif
}

/**
 * 软解路径的 hilog 记录。
 *
 * 为什么值得保留（而不是"调试完就删"）：软解这条链路最容易出的故障是**静默黑屏**
 * —— 帧在解、帧号在涨、没有异常、屏幕上什么都没有（实测根因：EGL 在别的线程初始化，
 * UI 线程每帧 `eglSwapBuffers` 报 `EGL_BAD_SURFACE`，上层看不到任何错误）。
 * 这几条记录刻意保持极低频率（关键节点 + 每 100 帧一条），用于把"何时起播、
 * 首帧何时上屏、渲染是否失败"变成可查的事实。
 */
void SoftLog(const std::string &message)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SoftPlay", "%{public}s", message.c_str());
}

/** 软解逐帧日志的间隔（每 100 帧一条，约 12~18 秒），既留痕又不刷屏 */
constexpr int64_t kSoftFirstFrameLogInterval = 100;

/**
 * 把 EGL 渲染器绑定到当前 XComponent surface（**只能在将来渲染的那个线程上调用**）。
 *
 * 为什么这件事必须单独抽出来、并且不能放在 `softPlayOpen` 里做：
 * `softPlayOpen` 是 `RunAsync`（libuv 工作线程），而 EGL/DGLES 的"当前上下文 / 当前
 * surface"是**线程私有**状态 —— 在工作线程初始化、在 UI 线程逐帧 `eglSwapBuffers`
 * 只会失败。设备实测（DevEco x86_64 模拟器，HEVC 源自动回退软解）：
 *   · 初始化发生在 tid=31744（工作线程）：`DGLES: Initialize display` 等日志都是该 tid；
 *   · 逐帧 swap 发生在 tid=31628（UI 线程，`softPlayRenderLast`）：每 70ms 一条
 *     `DGLES: EGL_BAD_SURFACE, g_handle is null`（0x300d）；
 *   · 结果：帧解出来了、帧号在涨，**屏幕全黑且没有任何上层报错** —— 即"软解黑屏"。
 * 因此初始化统一由宿主的 **UI 线程** 通过同步接口 `softPlayInitRenderer()` 发起，
 * 与帧循环里的 `softPlayRenderLast()` 保持同线程。
 *
 * @param allowInit false 时只做"复用判定"（供工作线程上的 `softPlayOpen` 使用）
 * @param reused    输出：是否复用了已就绪且仍绑在当前 surface 上的渲染器
 */
bool EnsureSoftRendererBound(const std::string &renderMode, uint64_t surfaceId, int width, int height,
                             bool allowInit, bool &reused, std::string &error, std::string *sizeText)
{
    reused = false;
    const bool xcomponentMode = renderMode.empty() || renderMode == "xcomponent";

    if (xcomponentMode) {
        // 官方路径：window 由 ArkUI 经 OH_NativeXComponent 回调给出（见 xcomponent_bridge）
        void *surfaceWindow = jellyfin::player::XComponentBridge::SurfaceWindow();
        if (surfaceWindow == nullptr) {
            error = jellyfin::player::XComponentBridge::IsRegistered()
                        ? "XComponent surface 尚未创建（等待 OnSurfaceCreated）"
                        : "未收到 OH_NativeXComponent：请确认 XComponent 指定了 libraryname";
            return false;
        }
        int surfaceW = 0;
        int surfaceH = 0;
        if (!jellyfin::player::XComponentBridge::SurfaceSize(surfaceW, surfaceH)) {
            // 尺寸取自 ArkTS 侧的组件实测值兜底
            surfaceW = width;
            surfaceH = height;
        }
        if (sizeText != nullptr) {
            *sizeText = std::to_string(surfaceW) + "x" + std::to_string(surfaceH);
        }
        // 复用条件：已就绪**且仍绑在同一块 window 上**。
        // 只判 `isReady()` 不够：渲染器是进程级单例，而 XComponent 的 surface 会随页面
        // 进出被销毁重建；沿用旧 surface 会让帧画到死掉的显示面上（不报错、画面不动）。
        if (SoftRenderer().isReady() && SoftRenderer().boundToWindow(surfaceWindow)) {
            reused = true;
            return true;
        }
        if (!allowInit) {
            error = "EGL 渲染器需在 UI 线程初始化（softPlayInitRenderer）";
            return false;
        }
        return SoftRenderer().initFromWindow(surfaceWindow, surfaceW, surfaceH, error,
                                            jellyfin::player::XComponentBridge::SurfaceGeneration());
    }

    if (renderMode == "texture") {
        // XComponent(TEXTURE)：surfaceId 是 GL 纹理 id，经 OH_NativeImage 渲染并发布
        if (SoftRenderer().isReady() && SoftRenderer().isTexturePath()) {
            reused = true;
            return true;
        }
        if (!allowInit) {
            error = "EGL 渲染器需在 UI 线程初始化（softPlayInitRenderer）";
            return false;
        }
        return SoftRenderer().initFromTexture(static_cast<uint32_t>(surfaceId), error, width, height);
    }

    // surfaceId 路径：window 由我们自己从 surfaceId 创建
    if (surfaceId == 0) {
        error = "surfaceId 为空（surface 尚未就绪）";
        return false;
    }
    // 复用判据同 xcomponent 路径：**必须**确认仍绑在同一块显示面上。
    // 只判 `isReady()` 会在"另一处（播放页/上一个页面）已经初始化过渲染器"时，
    // 把帧画到那块**别人的**表面上 —— 现象是画面完全不动且没有任何报错。
    if (SoftRenderer().isReady() && SoftRenderer().boundToSurfaceId(surfaceId)) {
        reused = true;
        return true;
    }
    if (!allowInit) {
        error = "EGL 渲染器需在 UI 线程初始化（softPlayInitRenderer）";
        return false;
    }
    return SoftRenderer().init(surfaceId, error, width, height);
}

/**
 * 在当前线程（宿主为 ArkTS 的 UI 线程）初始化/复用软解 EGL 渲染器。
 *
 * 参数：surfaceId、组件像素宽高、渲染模式（'' | 'xcomponent' | 'texture' | 'surface'）。
 * 返回：ok / renderReady / renderWidth / renderHeight / renderReused / xcomponentSize /
 *       renderError / surfaceGeneration / renderThreadId。
 *
 * 调用时机：`softPlayOpen` 成功之后、启动帧循环之前（见 PlayerPage.startSoftPlay）。
 * 这一步会做 `eglInitialize` + 着色器编译（实测约 35ms，一次播放只做一次），
 * 属于可接受的 UI 线程开销；而它换来的是"渲染与初始化同线程"这一硬约束的成立。
 */
napi_value SoftPlayInitRenderer(napi_env env, napi_callback_info info)
{
    std::string surfaceIdText;
    int64_t width = 0;
    int64_t height = 0;
    std::string renderMode;
    ReadStringArg(env, info, 0, surfaceIdText);
    ReadIntArg(env, info, 1, width);
    ReadIntArg(env, info, 2, height);
    ReadStringArg(env, info, 3, renderMode);
    uint64_t surfaceId = 0;
    try {
        surfaceId = surfaceIdText.empty() ? 0 : std::stoull(surfaceIdText);
    } catch (...) {
        surfaceId = 0;
    }

    std::string error;
    std::string sizeText;
    bool reused = false;
    const bool ready = EnsureSoftRendererBound(renderMode, surfaceId, static_cast<int>(width),
                                               static_cast<int>(height), true, reused, error,
                                               &sizeText);
    nlohmann::json out = {
        {"renderReady", ready},
        {"renderReused", reused},
        {"renderThreadId", SoftRenderer().renderThreadId()},
        {"surfaceGeneration", jellyfin::player::XComponentBridge::SurfaceGeneration()},
    };
    if (!sizeText.empty()) {
        out["xcomponentSize"] = sizeText;
    }
    if (ready) {
        out["renderWidth"] = SoftRenderer().renderWidth();
        out["renderHeight"] = SoftRenderer().renderHeight();
        const int degraded = SoftRenderer().degradeCount();
        if (degraded > 0) {
            out["renderDegraded"] = degraded;
        }
    } else if (!error.empty()) {
        out["renderError"] = error;
    }
    out["renderMode"] = renderMode.empty() ? "surface" : renderMode;
    SoftLog(std::string("softPlayInitRenderer ready=") + (ready ? "1" : "0")
            + " reused=" + (reused ? "1" : "0")
            + " mode=" + out["renderMode"].get<std::string>()
            + " geo=" + std::to_string(SoftRenderer().renderWidth()) + "x"
            + std::to_string(SoftRenderer().renderHeight())
            + (sizeText.empty() ? std::string() : (" surface=" + sizeText))
            + " tid=" + std::to_string(SoftRenderer().renderThreadId())
            + " err=" + error);
    // 注意：即便渲染器没起来也返回 ok=true（会话仍在），由宿主决定是否继续 ——
    // 但宿主**必须**按 renderReady 判断，否则就是"看着在播、屏幕全黑"。
    return ToNapiJson(env, MakeResult(true, 200, "ok", out));
}

/**
 * 打开软解会话。
 *
 * 注意：**本函数不再初始化 EGL 渲染器**（它跑在 RunAsync 工作线程上，见
 * `EnsureSoftRendererBound` 的说明），只做"渲染器是否已在本 surface 上就绪"的判定；
 * 真正的初始化由宿主在 UI 线程调用同步接口 `softPlayInitRenderer()` 完成。
 *
 * @param surfaceId XComponent 的 surface id（字符串形式的 uint64）
 */
napi_value SoftPlayOpen(napi_env env, napi_callback_info info)
{
    EnsureRangeFetcher();
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    std::string surfaceIdText;
    int64_t surfaceWidth = 0;
    int64_t surfaceHeight = 0;
    std::string renderMode;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, surfaceIdText);
    ReadIntArg(env, info, 2, surfaceWidth);
    ReadIntArg(env, info, 3, surfaceHeight);
    ReadStringArg(env, info, 4, renderMode);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    nlohmann::json optionsJson;
    ReadJsonArg(env, info, 5, optionsJson);
    const auto options = ParsePlaybackOptionsJson(optionsJson);
    const std::string userId = session.userId();

    return RunAsync(env, [userId, itemId, surfaceIdText, surfaceWidth, surfaceHeight, renderMode, options]() {
        nlohmann::json out;
        out["ffmpegAvailable"] = jellyfin::player::SoftDecodeSession::available();
        bool profileFallback = false;
        auto playback = PostPlaybackInfoWithProfileFallback(itemId, userId, options, profileFallback);
        if (profileFallback) {
            out["deviceProfileFallback"] = true;
        }
        if (!playback.ok()) {
            out["ok"] = false;
            out["error"] = "获取播放信息失败：" + playback.error.message;
            return MakeResult(true, 200, "ok", out).dump();
        }
        if (playback.data.is_object() && !playback.data.contains("ItemId")) {
            playback.data["ItemId"] = itemId;
        }
        auto &sess = jellyfin::SessionManager::instance();
        jellyfin::player::PlaybackSession pbSession;
        std::string resolveError;
        if (!jellyfin::player::ResolvePlaybackSession(playback.data, sess.baseUrl(), sess.accessToken(),
                                                     pbSession, resolveError)) {
            out["ok"] = false;
            out["error"] = resolveError.empty() ? "无法解析播放地址" : resolveError;
            return MakeResult(true, 200, "ok", out).dump();
        }
        out["playMethod"] = jellyfin::player::PlayMethodToString(pbSession.method);
        // 软解会话消费的是**直连文件**（FFmpeg 按 Range 取字节，见 softPlayOpen 的说明），
        // 因此进度上报按 DirectStream 记账；同时刷新 MediaSource / PlaySession，
        // 否则软解期间上报的 MediaSourceId 还停在上一次硬解用的那个源上。
        {
            std::lock_guard<std::mutex> lock(g_playbackMutex);
            CurrentPlayMethod = "DirectStream";
            if (!pbSession.playSessionId.empty()) {
                CurrentPlaySessionId = pbSession.playSessionId;
            }
            if (!pbSession.mediaSourceId.empty()) {
                CurrentMediaSourceId = pbSession.mediaSourceId;
            }
        }

        // EGL 渲染器：**只复用、不初始化**。
        //
        // 本函数跑在 RunAsync 的工作线程上，而 EGL 上下文是线程私有的 —— 在这里
        // `eglInitialize` 会让之后 UI 线程的 `eglSwapBuffers` 每帧失败（EGL_BAD_SURFACE，
        // 画面全黑无报错）。因此这里只判定"渲染器是否已就绪且仍绑在当前 surface 上"，
        // 未就绪时把 `renderNeedsInit` 交给宿主，由宿主在 UI 线程调用
        // `softPlayInitRenderer()` 完成初始化。
        std::string renderError;
        bool renderReady = false;
        if (!surfaceIdText.empty()) {
            uint64_t surfaceId = 0;
            try {
                surfaceId = std::stoull(surfaceIdText);
            } catch (...) {
                surfaceId = 0;
            }
            if (surfaceId != 0 || renderMode == "xcomponent") {
                bool reused = false;
                std::string sizeText;
                renderReady = EnsureSoftRendererBound(renderMode, surfaceId,
                                                      static_cast<int>(surfaceWidth),
                                                      static_cast<int>(surfaceHeight),
                                                      /*allowInit=*/false, reused, renderError,
                                                      &sizeText);
                if (!sizeText.empty()) {
                    out["xcomponentSize"] = sizeText;
                }
                if (reused) {
                    out["renderReused"] = true;
                }
                out["renderMode"] = renderMode.empty() ? "surface" : renderMode;
            }
        }
        out["renderReady"] = renderReady;
        if (!renderReady) {
            // 宿主据此知道"必须先在自己的线程上初始化渲染器"（见 softPlayInitRenderer）
            out["renderNeedsInit"] = true;
            if (!renderError.empty()) {
                out["renderError"] = renderError;
            }
        }
        // 渲染缓冲的**实际**像素几何：宿主据此决定解码目标尺寸，避免"解码到 640 宽再被放大"
        // 这种无谓降质，也避免解码到远超缓冲的尺寸白烧 CPU。
        if (renderReady) {
            out["renderWidth"] = SoftRenderer().renderWidth();
            out["renderHeight"] = SoftRenderer().renderHeight();
            const int degraded = SoftRenderer().degradeCount();
            if (degraded > 0) {
                out["renderDegraded"] = degraded;
            }
        }

        auto session = std::make_shared<jellyfin::player::SoftDecodeSession>();
        SetSoftSession(session);
        std::string error;
        const auto openStart = std::chrono::steady_clock::now();
        if (!session->openUrl(pbSession.playUrl, error)) {
            SetSoftSession(nullptr);
            // 注意：**不销毁渲染器**。本函数在工作线程上运行，而 EGL 上下文是渲染线程
            // （UI 线程）私有的 —— 在这里销毁 EGL 对象属于跨线程操作。
            // 渲染器已经绑在当前 surface 上，留着下次直接复用即可（见 softPlayInitRenderer）。
            out["ok"] = false;
            out["error"] = error;
            SoftLog("softPlayOpen 打开失败：" + error);
            return MakeResult(true, 200, "ok", out).dump();
        }
        const auto openMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - openStart)
                                .count();
        SoftLog("softPlayOpen ok codec=" + session->videoCodec()
                + " decoder=" + session->decoderName()
                + " pick=" + session->decoderNote()
                + " container=" + session->container()
                + " size=" + std::to_string(session->width()) + "x"
                + std::to_string(session->height())
                + " decodeThreads=" + std::to_string(session->decoderThreads())
                + " openMs=" + std::to_string(openMs));
        out["ok"] = true;
        out["container"] = session->container();
        out["videoCodec"] = session->videoCodec();
        // 解码器名一并回给宿主：AV1 是否拿到 dav1d 直接决定能不能出画面（见 README「AV1 软解」）
        out["decoder"] = session->decoderName();
        out["decoderPick"] = session->decoderNote();
        out["width"] = session->width();
        out["height"] = session->height();
        out["durationSec"] = session->durationSec();
        return MakeResult(true, 200, "ok", out).dump();
    });
}

/**
 * 取下一帧：解码 → 存最近帧 → （有渲染器时）EGL 渲染上屏。
 *
 * **必须异步执行**（`RunAsync`）：这一路会走 `RangeCache::read`，未命中缓存时是**同步 HTTP**。
 * 设备实测（faultlog 主线程栈 `RangeCache::read → fillCache → FetchRange → THREAD_BLOCK_6S`）：
 * 同步执行时逐帧拉取会在 UI 线程上做网络请求，一次往返就把主线程阻塞 6 秒以上，
 * 系统判 appfreeze、界面直接消失。放到工作线程后，UI 线程只等 Promise，不阻塞。
 *
 * EGL 渲染放在工作线程是安全的：`EglRenderer` 每次绘制前都会 `eglMakeCurrent`
 * （见 egl_renderer.cpp 的绘制辅助函数），上下文与线程的绑定由它自己保证；
 * 宿主侧（PlayerPage）有 `softPulling` 标志保证同一时刻只有一次拉取在飞。
 */
napi_value SoftPlayNextFrame(napi_env env, napi_callback_info info)
{
    // 取一份会话引用并**带进异步任务**：宿主可能在本次调用飞在半空时调 softPlayClose
    // （看门狗/退出播放页），只捕获裸指针或每处现取单例都会踩到已析构对象（见 SoftSession 注释）。
    auto session = SoftSession();
    if (session == nullptr) {
        return ToNapiJson(env, MakeResult(false, 0, "会话未打开"));
    }
    int64_t maxWidth = 0;
    ReadIntArg(env, info, 0, maxWidth);
    const int64_t cappedWidth = maxWidth > 0 ? maxWidth : 0;
    return RunAsync(env, [cappedWidth, session]() {
        std::vector<uint8_t> rgba;
        jellyfin::player::SoftDecodeSession::FrameInfo frameInfo;
        // 软解速度（fps）的计时起点：首帧到达时记一次，之后每 100 帧打印实际帧率。
        // 这是"解码效率优化有没有效果"的唯一直接证据（见 openUrl 的多核设置）。
        static std::chrono::steady_clock::time_point fpsStart;
        static int64_t fpsStartFrame = 0;
        const auto decodeStart = std::chrono::steady_clock::now();
        const bool ok = session->nextFrameRgba(
            cappedWidth > 0 ? static_cast<int>(cappedWidth) : 0, rgba, frameInfo);
        const auto decodeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - decodeStart)
                                  .count();

        nlohmann::json out = {
            {"ok", ok},
            {"width", frameInfo.width},
            {"height", frameInfo.height},
            {"ptsSec", frameInfo.ptsSec},
            {"frameIndex", frameInfo.frameIndex},
            {"bytesFetched", session->bytesFetched()},
            // 排队的 seek 结果：宿主据此知道"跳转到底生效了没有"（此前只能看到位置没变，
            // 无法区分"还没执行"与"执行失败"）。
            {"seekApplied", frameInfo.seekApplied},
            {"seekedToSec", frameInfo.seekedToSec},
            // 解码器名随每一帧回给宿主：失败提示里能直接说清"是哪个解码器解不出来"
            {"decoder", session->decoderName()},
        };
        if (!frameInfo.seekError.empty()) {
            out["seekError"] = frameInfo.seekError;
        }
        if (!frameInfo.error.empty()) {
            out["error"] = frameInfo.error;
        }
        // 首帧与每 100 帧一条：用于把"起播后多久出第一帧 / 解码有多慢"变成可查事实
        if (ok && (frameInfo.frameIndex == 1 ||
                   frameInfo.frameIndex % kSoftFirstFrameLogInterval == 0)) {
            if (frameInfo.frameIndex == 1) {
                fpsStart = std::chrono::steady_clock::now();
                fpsStartFrame = 1;
            }
            const int64_t elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                          std::chrono::steady_clock::now() - fpsStart)
                                          .count();
            const int64_t framesSinceStart = frameInfo.frameIndex - fpsStartFrame;
            const double fps = (elapsedMs > 0 && framesSinceStart > 0)
                                   ? (static_cast<double>(framesSinceStart) * 1000.0
                                      / static_cast<double>(elapsedMs))
                                   : 0.0;
            SoftLog("softPlayNextFrame #" + std::to_string(frameInfo.frameIndex)
                    + " pts=" + std::to_string(frameInfo.ptsSec)
                    + " " + std::to_string(frameInfo.width) + "x"
                    + std::to_string(frameInfo.height)
                    + " decodeMs=" + std::to_string(decodeMs)
                    + " fps=" + std::to_string(static_cast<int>(fps * 10) / 10)
                    + " fetched=" + std::to_string(session->bytesFetched()));
        }
        // ── 失败必须留痕（本工程踩过的最贵的一个坑）─────────────────────────
        // 此前这里**只在成功时**打印，于是 AV1 那种"每一包都被解码器拒绝、一帧都出不来"
        // 的情况在 hilog 里连一行都没有：上层看到 eof、用户看到黑屏，谁都查不出原因。
        // 现在：首帧失败立即打印（带错误原因与解码器名），此后每 100 次失败再打印一次。
        if (!ok) {
            static int64_t failCount = 0;
            failCount++;
            if (failCount == 1 || failCount % kSoftFirstFrameLogInterval == 0) {
                SoftLog("softPlayNextFrame 失败 #" + std::to_string(failCount)
                        + " decoder=" + session->decoderName()
                        + " reason=" + (frameInfo.error.empty() ? "未知" : frameInfo.error)
                        + " frames=" + std::to_string(session->framesDecoded())
                        + " fetched=" + std::to_string(session->bytesFetched()));
            }
        }
        // 排队的 seek 落地（成功/失败都要留痕：这是"续播/跳转到底有没有生效"的唯一事实来源）
        if (frameInfo.seekApplied) {
            SoftLog("seek applied to=" + std::to_string(frameInfo.seekedToSec) + "s frame=#"
                    + std::to_string(frameInfo.frameIndex));
        } else if (!frameInfo.seekError.empty()) {
            SoftLog("seek 失败：" + frameInfo.seekError);
        }
        bool rendered = false;
        std::string renderError;
        if (ok && !rgba.empty()) {
            {
                std::lock_guard<std::mutex> lock(SoftLastFrameMutex());
                SoftLastFrame() = rgba;
                SoftLastFrameWidth() = frameInfo.width;
                SoftLastFrameHeight() = frameInfo.height;
            }
            // 这里**不做渲染**：EGL 的窗口 surface 不能跨到线程池线程上 swap
            // （设备实测：从工作线程渲染时 `eglSwapBuffers` 返回 0x12301，帧解出来但上不了屏）。
            // 渲染交给宿主在 UI 线程调用 `softPlayRenderLast()`。
        }
        out["rendered"] = rendered;
        if (!renderError.empty()) {
            out["renderError"] = renderError;
        }
        return MakeResult(true, 200, "ok", out).dump();
    });
}

/**
 * 把最近一帧解码结果渲染上屏（EGL）。
 *
 * 为什么单独一个**同步**方法、且必须由 UI 线程调用：EGL 窗口 surface 的 swap 有线程约束
 * —— 设备实测在工作线程池里 swap 返回 `0x12301`（帧解出来了但屏幕不变），
 * 而 UI 线程调用与改动前完全一致、可正常上屏。渲染本身不做网络/解码，不会长时间占用 UI 线程。
 */
napi_value SoftPlayRenderLast(napi_env env, napi_callback_info /*info*/)
{
    std::vector<uint8_t> rgba;
    int width = 0;
    int height = 0;
    {
        std::lock_guard<std::mutex> lock(SoftLastFrameMutex());
        rgba = SoftLastFrame();
        width = SoftLastFrameWidth();
        height = SoftLastFrameHeight();
    }
    bool rendered = false;
    std::string renderError;
    if (rgba.empty()) {
        renderError = "还没有可渲染的帧";
    } else if (!SoftRenderer().isReady()) {
        renderError = "渲染器未就绪";
    } else {
        // ── surface 重建的**自愈**点 ──────────────────────────────────────────
        // XComponent 的 surface 会因页面重进/旋转被销毁重建，而渲染器是进程级单例、
        // 仍指着旧的 window。只按 `isReady()` 复用会把帧画到已死掉的显示面上
        // （不报错、画面不动 —— 同样是"软解黑屏"的一种）。
        // 本函数恰好运行在**渲染线程**（宿主为 UI 线程）上，正是唯一能安全重建 EGL 的地方，
        // 因此这里发现 window 变了就地重新绑定，让播放跨 surface 重建继续。
        void *currentWindow = jellyfin::player::XComponentBridge::SurfaceWindow();
        if (currentWindow != nullptr && !SoftRenderer().isTexturePath()
            && !SoftRenderer().boundToWindow(currentWindow)) {
            int sizeW = 0;
            int sizeH = 0;
            if (!jellyfin::player::XComponentBridge::SurfaceSize(sizeW, sizeH)) {
                sizeW = SoftRenderer().renderWidth();
                sizeH = SoftRenderer().renderHeight();
            }
            std::string bindError;
            if (!SoftRenderer().initFromWindow(currentWindow, sizeW, sizeH, bindError,
                                              jellyfin::player::XComponentBridge::SurfaceGeneration())) {
                renderError = "XComponent surface 已重建，重新绑定渲染器失败：" + bindError;
            }
        }
        if (renderError.empty()) {
            rendered = SoftRenderer().renderRgba(rgba.data(), width, height, renderError);
        }
    }
    // 上屏结果：首次成功、以及**每一次失败**都要留痕（静默黑屏正是"失败没人知道"）
    if (rendered) {
        static int renderedCount = 0;
        ++renderedCount;
        if (renderedCount == 1 || renderedCount % kSoftFirstFrameLogInterval == 0) {
            SoftLog("softPlayRenderLast ok #" + std::to_string(renderedCount)
                    + " frame=" + std::to_string(width) + "x" + std::to_string(height));
        }
    } else {
        static int renderFailCount = 0;
        ++renderFailCount;
        if (renderFailCount <= 3 || renderFailCount % 50 == 0) {
            SoftLog("softPlayRenderLast 失败 #" + std::to_string(renderFailCount) + "：" + renderError);
        }
    }
    nlohmann::json data = {
        {"rendered", rendered},
        {"renderError", renderError},
        {"renderThreadId", SoftRenderer().renderThreadId()},
    };
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
}

/**
 * 回读当前渲染缓冲并写成 PNG（验证"真的渲染出来了"，与系统截图无关）。
 *
 * 关键：**先重绘最近一帧再回读**。`eglSwapBuffers` 之后后台缓冲内容未定义，
 * 直接读会得到全黑（实测 1260x2619 全黑），会误判为"渲染失败"。
 * 参数：输出路径。渲染器未就绪时退化为导出最近一帧解码结果。
 */
napi_value SoftPlayDumpFrame(napi_env env, napi_callback_info info)
{
    std::string path;
    ReadStringArg(env, info, 0, path);
    if (path.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "path required"));
    }
    nlohmann::json out;
    std::string error;
    bool ok = false;
    if (SoftRenderer().isReady()) {
        std::vector<uint8_t> pixels;
        int w = 0;
        int h = 0;
        std::lock_guard<std::mutex> lock(SoftLastFrameMutex());
        const bool hasFrame = !SoftLastFrame().empty() && SoftLastFrameWidth() > 0 &&
                              SoftLastFrameHeight() > 0;
        const bool readOk = hasFrame
            ? SoftRenderer().redrawAndReadback(SoftLastFrame().data(), SoftLastFrameWidth(),
                                               SoftLastFrameHeight(), pixels, w, h, error)
            : SoftRenderer().readbackRgba(pixels, w, h, error);
        if (readOk) {
            ok = WriteRgbaPng(pixels, w, h, path, error);
            out["source"] = hasFrame ? "glReadPixels(after-redraw)" : "glReadPixels(no-frame)";
            out["width"] = w;
            out["height"] = h;
        }
    }
    if (!ok && error.empty()) {
        // 退化路径：导出最近一帧解码结果（便于区分"没渲染"与"没解码"）
        std::lock_guard<std::mutex> lock(SoftLastFrameMutex());
        if (!SoftLastFrame().empty() && SoftLastFrameWidth() > 0 && SoftLastFrameHeight() > 0) {
            ok = WriteRgbaPng(SoftLastFrame(), SoftLastFrameWidth(), SoftLastFrameHeight(), path,
                              error);
            out["source"] = "last-decoded-frame";
            out["width"] = SoftLastFrameWidth();
            out["height"] = SoftLastFrameHeight();
        }
    }
    // 对照导出：无论上面成功与否，都把"最近解码帧"另存一份，
    // 从而能区分"解码出来就是黑"与"解码正常但绘制/回读没出内容"（本轮排查所需）。
    {
        std::lock_guard<std::mutex> lock(SoftLastFrameMutex());
        if (!SoftLastFrame().empty() && SoftLastFrameWidth() > 0 && SoftLastFrameHeight() > 0) {
            const std::string decodedPath = path + ".decoded.png";
            std::string decodedError;
            if (WriteRgbaPng(SoftLastFrame(), SoftLastFrameWidth(), SoftLastFrameHeight(), decodedPath,
                             decodedError)) {
                out["decodedFramePath"] = decodedPath;
                out["decodedFrameWidth"] = SoftLastFrameWidth();
                out["decodedFrameHeight"] = SoftLastFrameHeight();
            } else {
                out["decodedFrameError"] = decodedError;
            }
        }
    }
    out["ok"] = ok;
    if (!error.empty()) {
        out["error"] = error;
    }
    return ToNapiJson(env, MakeResult(ok, ok ? 200 : 0, ok ? "ok" : error, out));
}

napi_value SoftPlayStatus(napi_env env, napi_callback_info /*info*/)
{
    nlohmann::json out;
    out["ffmpegAvailable"] = jellyfin::player::SoftDecodeSession::available();
    auto session = SoftSession();
    if (session != nullptr) {
        out["open"] = session->isOpen();
        out["videoCodec"] = session->videoCodec();
        out["container"] = session->container();
        out["width"] = session->width();
        out["height"] = session->height();
        out["durationSec"] = session->durationSec();
        out["framesDecoded"] = session->framesDecoded();
        out["bytesFetched"] = session->bytesFetched();
        // 阶段快照：宿主看门狗判定"卡死"时据此说明**卡在哪一步**（见 StageSnapshot 说明）。
        // 这是一次独立的同步调用（UI 线程），不会与正在飞的解码调用抢锁 —— 全部是原子读。
        const auto stage = session->stageSnapshot();
        const char *stageName = "idle";
        switch (stage.stage) {
        case jellyfin::player::SoftDecodeSession::Stage::ReceiveFrame: stageName = "receiveFrame"; break;
        case jellyfin::player::SoftDecodeSession::Stage::ReadPacket: stageName = "readPacket"; break;
        case jellyfin::player::SoftDecodeSession::Stage::SendPacket: stageName = "sendPacket"; break;
        case jellyfin::player::SoftDecodeSession::Stage::Scale: stageName = "swsScale"; break;
        default: stageName = "idle"; break;
        }
        out["stage"] = stageName;
        out["stageMs"] = static_cast<double>(stage.stageMs);
        out["callMs"] = static_cast<double>(stage.callMs);
        out["callPackets"] = stage.packetsRead;
        out["sendRejects"] = stage.sendRejects;
        out["decoder"] = session->decoderName();
        out["decoderThreads"] = session->decoderThreads();
    } else {
        out["open"] = false;
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok", out));
}

/**
 * 渲染目标判定（无需开始播放）：给 surfaceId 就初始化 EGL 并跑一次"清屏为红 + 回读"自检。
 * 用途：打开播放页即可自动判定该设备/该 XComponent 类型能否作为 GL 渲染目标，
 * 不依赖任何播放状态与控制条交互（设备自动化下最可靠）。
 */
napi_value RenderTargetProbe(napi_env env, napi_callback_info info)
{
    std::string surfaceIdText;
    int64_t width = 0;
    int64_t height = 0;
    std::string renderMode;
    ReadStringArg(env, info, 0, surfaceIdText);
    ReadIntArg(env, info, 1, width);
    ReadIntArg(env, info, 2, height);
    ReadStringArg(env, info, 3, renderMode);

    nlohmann::json out;
    out["mode"] = renderMode.empty() ? "surface" : renderMode;
    if (surfaceIdText.empty()) {
        out["ok"] = false;
        out["error"] = "surfaceId 为空（surface 尚未就绪）";
        return ToNapiJson(env, MakeResult(false, 0, "surfaceId required", out));
    }
    uint64_t surfaceId = 0;
    try {
        surfaceId = std::stoull(surfaceIdText);
    } catch (...) {
        surfaceId = 0;
    }
    if (surfaceId == 0) {
        out["ok"] = false;
        out["error"] = "surfaceId 解析为 0";
        return ToNapiJson(env, MakeResult(false, 0, "invalid surfaceId", out));
    }

    std::string initError;
    bool ready = false;
    if (out["mode"] == "xcomponent") {
        // 官方路径：window 来自 OH_NativeXComponent 回调（xcomponent_bridge）
        void *surfaceWindow = jellyfin::player::XComponentBridge::SurfaceWindow();
        int surfaceW = 0;
        int surfaceH = 0;
        if (!jellyfin::player::XComponentBridge::SurfaceSize(surfaceW, surfaceH)) {
            surfaceW = static_cast<int>(width);
            surfaceH = static_cast<int>(height);
        }
        if (surfaceWindow == nullptr) {
            initError = jellyfin::player::XComponentBridge::IsRegistered()
                            ? "XComponent 已注册但 surface 尚未创建（等待 OnSurfaceCreated）"
                            : "未收到 OH_NativeXComponent：请确认 XComponent 指定了 libraryname";
        } else {
            out["xcomponentSize"] = std::to_string(surfaceW) + "x" + std::to_string(surfaceH);
            ready = SoftRenderer().initFromWindow(surfaceWindow, surfaceW, surfaceH, initError,
                                                 jellyfin::player::XComponentBridge::SurfaceGeneration());
        }
    } else if (out["mode"] == "texture") {
        ready = SoftRenderer().initFromTexture(static_cast<uint32_t>(surfaceId), initError,
                                               static_cast<int>(width), static_cast<int>(height));
    } else {
        ready = SoftRenderer().init(surfaceId, initError, static_cast<int>(width),
                                    static_cast<int>(height));
    }
    out["rendererReady"] = ready;
    if (!ready) {
        out["ok"] = false;
        out["error"] = initError.empty() ? "EGL 初始化失败" : initError;
        return ToNapiJson(env, MakeResult(false, 0, out["error"].get<std::string>(), out));
    }
    std::string report;
    const bool renderable = SoftRenderer().selfTest(report);
    out["ok"] = renderable;
    out["renderable"] = renderable;
    out["report"] = report;
    // 探测**不销毁**渲染器：保留它已建立好的 EGL surface。
    // 实测教训：探测跑完 destroy 之后，软解会在同一个 XComponent window 上重建 EGL surface，
    // 而第二次创建的表面 swap 报 0x12301（首个表面正常）。现在 `destroy()` 已经不再销毁
    // framework 的 window（见 EglRenderer::destroy 的归属说明），但"同一 window 上二次初始化"
    // 仍是该模拟器上已验证过的坑，因此这里依旧保留渲染器、由 `softPlayInitRenderer` 复用。
    // 另注：本探测是**同步**接口（跑在 ArkTS 的 UI 线程上），与帧循环渲染同线程 ——
    // 这也是它能 swap 成功、而当初在工作线程初始化的软解路径不能的原因。
    return ToNapiJson(env, MakeResult(true, 200, "ok", out));
}

/** 渲染自检：清屏为红并回读，判断 surface 能否作为 GL 渲染目标 */
napi_value SoftPlaySelfTest(napi_env env, napi_callback_info /*info*/)
{
    nlohmann::json out;
    out["rendererReady"] = SoftRenderer().isReady();
    if (!SoftRenderer().isReady()) {
        out["ok"] = false;
        out["error"] = "渲染器未就绪（EGL 未初始化）";
        return ToNapiJson(env, MakeResult(false, 0, "renderer not ready", out));
    }
    std::string report;
    const bool ok = SoftRenderer().selfTest(report);
    out["ok"] = ok;
    out["report"] = report;
    return ToNapiJson(env, MakeResult(true, 200, "ok", out));
}

napi_value SoftPlayClose(napi_env env, napi_callback_info /*info*/)
{
    // 关闭：从单例摘下来即可。**不要在这里销毁对象** —— 可能有一次 nextFrameRgba 正在
    // 工作线程上跑（它持有自己的 shared_ptr，用完自然析构）。若在这里强行 close()，
    // 等于把正在解码的上下文从工作线程脚下抽走（数据竞争 + 崩溃）。
    if (SoftSession() != nullptr) {
        SetSoftSession(nullptr);
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok", nlohmann::json{{"closed", true}}));
}

/**
 * 软解会话 seek：**只排队**，真正的 `av_seek_frame` 由下一次 `softPlayNextFrame`
 * （工作线程）执行，并把结果放进那一帧的 JSON（`seekApplied` / `seekedTo` / `seekError`）。
 *
 * 为什么不在这里直接 seek（本次改动的原因）：`av_seek_frame` 会经自定义 AVIO 回调做
 * **同步 HTTP Range 取流**，在 ArkTS（UI 线程）调用就是"UI 线程做网络 I/O"，
 * 而且会与解码线程并发操作同一个 AVFormatContext。表现是设备实测"软解播放中按 ±10s /
 * 拖动进度条没有反应"。排队后 UI 侧立即返回，seek 与解码在同一条线程上串行。
 *
 * 参数：positionSec（目标时间点，秒）。
 */
napi_value SoftPlaySeek(napi_env env, napi_callback_info info)
{
    auto session = SoftSession();
    if (session == nullptr || !session->isOpen()) {
        return ToNapiJson(env, MakeResult(false, 0, "软解会话未打开"));
    }
    double positionSec = 0.0;
    {
        size_t argc = 1;
        napi_value args[1] = {};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc >= 1) {
            napi_get_value_double(env, args[0], &positionSec);
        }
    }
    session->requestSeek(positionSec);
    SoftLog("softPlaySeek queued target=" + std::to_string(positionSec) + "s");
    nlohmann::json data = {
        {"ok", true},
        {"queued", true},
        {"positionSec", positionSec},
    };
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
}

/**
 * 设置软解画面的缩放模式（「视频比例」在软解路径上的落点）。
 *
 * 参数：mode —— 0 适应 / 1 填充 / 2 拉伸 / 3 原始（对应 ScaleMode，
 * 与 ArkTS 的 PlayerAspectMode 顺序一致）。渲染器未就绪时也允许设置，
 * 值会被记住并在渲染器就绪后生效（用户可能在软解打开前就切了比例）。
 */
napi_value SoftPlaySetScale(napi_env env, napi_callback_info info)
{
    int64_t mode = 0;
    ReadIntArg(env, info, 0, mode);
    if (mode < 0 || mode > 3) {
        return ToNapiJson(env, MakeResult(false, 0, "缩放模式非法（应为 0-3）"));
    }
    SoftRenderer().setScaleMode(static_cast<jellyfin::player::ScaleMode>(mode));
    nlohmann::json data = {
        {"mode", mode},
        {"rendererReady", SoftRenderer().isReady()},
    };
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
}

/**
 * 读取 XComponent 视频区域的最新触摸事件（由 OnDispatchTouchEvent 捕获）。
 *
 * 官方文档：`OH_NativeXComponent_GetTouchEvent` 获取触摸点与动作。
 * 返回：{type, x, y, numPoints, timestamp, valid}
 * 无新事件时 valid=false。
 */
napi_value GetXComponentTouchEvent(napi_env env, napi_callback_info /*info*/)
{
    jellyfin::player::TouchEventData touch;
    const bool hasEvent = jellyfin::player::XComponentBridge::TakeTouchEvent(touch);
    nlohmann::json data = {
        {"type", touch.type},
        {"x", touch.x},
        {"y", touch.y},
        {"numPoints", touch.numPoints},
        {"timestamp", touch.timestamp},
        {"valid", hasEvent},
    };
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
}

/**
 * 软解码探测：解析播放地址 → 取文件前缀字节 → 用 FFmpeg 软解出前若干帧。
 *
 * 用途：
 *  - 设备上验证 FFmpeg 软解链路（系统 AVPlayer 解不了的编码，如模拟器上的 HEVC）
 *  - 为后续"硬解失败自动回落软解"提供能力探测
 *
 * 参数：itemId, cacheDir（可写目录，用于落盘首帧 PNG；可为空）, optionsJson（同 playerOpen）
 * 返回：{ok, ffmpegAvailable, playMethod, httpStatus, bytesFetched,
 *        container, videoCodec, audioCodec, width, height, pixelFormat,
 *        durationSec, bitRate, decodedFrames, framePngPath, error}
 */
napi_value PlayerSoftDecodeProbe(napi_env env, napi_callback_info info)
{
    EnsureRangeFetcher();
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    std::string itemId;
    std::string cacheDir;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, cacheDir);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId required"));
    }
    nlohmann::json optionsJson;
    ReadJsonArg(env, info, 2, optionsJson);
    const auto options = ParsePlaybackOptionsJson(optionsJson);
    const std::string userId = session.userId();

    return RunAsync(env, [userId, itemId, cacheDir, options]() {
        nlohmann::json out;
        out["ffmpegAvailable"] = jellyfin::player::FfmpegDecoder::available();

        // 1) 解析播放地址（与 playerOpen 走同一条 PlaybackInfo + 策略解析路径）
        bool probeFallback = false;
        auto playback = PostPlaybackInfoWithProfileFallback(itemId, userId, options, probeFallback);
        if (probeFallback) {
            out["deviceProfileFallback"] = true;
        }
        if (!playback.ok()) {
            out["ok"] = false;
            out["error"] = "获取播放信息失败：" + playback.error.message;
            return MakeResult(true, 200, "ok", out).dump();
        }
        if (playback.data.is_object() && !playback.data.contains("ItemId")) {
            playback.data["ItemId"] = itemId;
        }
        auto &sess = jellyfin::SessionManager::instance();
        jellyfin::player::PlaybackSession pbSession;
        std::string resolveError;
        if (!jellyfin::player::ResolvePlaybackSession(playback.data, sess.baseUrl(), sess.accessToken(),
                                                     pbSession, resolveError)) {
            out["ok"] = false;
            out["error"] = resolveError.empty() ? "无法解析播放地址" : resolveError;
            return MakeResult(true, 200, "ok", out).dump();
        }
        out["playMethod"] = jellyfin::player::PlayMethodToString(pbSession.method);
        out["container"] = pbSession.container;
        out["videoCodec"] = pbSession.videoCodec;
        out["audioCodec"] = pbSession.audioCodec;

        // 2) 取文件前缀：探测只需容器头 + 前若干帧，避免整片下载；
        //    用 Range 请求，失败（如服务器不支持）则退化为普通 GET
        constexpr size_t kPrefixBytes = 8u * 1024u * 1024u;
        jellyfin::HttpClient http;
        http.setReadTimeoutSec(60);
        jellyfin::HttpHeaders headers;
        headers["Range"] = "bytes=0-" + std::to_string(kPrefixBytes - 1);
        jellyfin::HttpResponse resp = http.get(pbSession.playUrl, headers);
        if (resp.status >= 400 || resp.body.size() < 1024) {
            jellyfin::HttpResponse plain = http.get(pbSession.playUrl, {});
            if (plain.status < 400 && plain.body.size() >= 1024) {
                resp = plain;
            }
        }
        out["httpStatus"] = resp.status;
        out["bytesFetched"] = static_cast<double>(resp.body.size());
        if (resp.body.size() < 1024) {
            out["ok"] = false;
            out["error"] = resp.error.empty()
                ? ("取流失败：HTTP " + std::to_string(resp.status) + "，仅取到 " +
                   std::to_string(resp.body.size()) + " 字节")
                : ("取流失败：" + resp.error);
            return MakeResult(true, 200, "ok", out).dump();
        }

        // 3) FFmpeg 软解
        std::vector<uint8_t> data(resp.body.begin(), resp.body.end());
        std::string pngPath;
        if (!cacheDir.empty()) {
            pngPath = cacheDir + "/softdecode_probe.png";
        }
        jellyfin::player::FfmpegDecoder::ProbeResult result;
        jellyfin::player::FfmpegDecoder::probeFromMemory(data, pngPath, result, 3);

        out["ok"] = result.ok;
        out["backend"] = result.backend;
        out["decodedFrames"] = result.decodedFrames;
        out["framePngPath"] = result.framePngPath;
        if (!result.error.empty()) {
            out["error"] = result.error;
        }
        if (result.ok) {
            out["container"] = result.container.empty() ? out["container"] : nlohmann::json(result.container);
            out["videoCodec"] = result.videoCodec.empty() ? out["videoCodec"] : nlohmann::json(result.videoCodec);
            if (!result.audioCodec.empty()) {
                out["audioCodec"] = result.audioCodec;
            }
            out["width"] = result.width;
            out["height"] = result.height;
            out["pixelFormat"] = result.pixelFormat;
            out["durationSec"] = result.durationSec;
            out["bitRate"] = result.bitRate;
        }
        return MakeResult(true, 200, "ok", out).dump();
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
        bool profileFallback = false;
        auto playback = PostPlaybackInfoWithProfileFallback(itemId, userId, options, profileFallback);
        if (!playback.ok()) {
            return FromApi(playback).dump();
        }
        if (profileFallback) {
            SoftLog("playerOpen 使用直连保底路径（服务端未给出转码地址）");
        }
        if (playback.data.is_object() && !playback.data.contains("ItemId")) {            playback.data["ItemId"] = itemId;
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
            // 进度上报要如实带上播放方式（转码必须让服务端知道，见 CurrentPlayMethod）
            CurrentPlayMethod = jellyfin::player::PlayMethodToString(pbSession.method);
        }
        Progress().reset();

        // 播放方式必须留痕：这是"到底走的是直连 / 直接串流 / 服务器转码"的唯一事实来源
        // （排查 AV1 这类"转码还是软解"的问题时，光看画面分不出是哪一条路）。
        // ⚠ 只记录**去掉查询串**的 URL：Jellyfin 的直连地址里带 api_key，属于敏感信息。
        {
            std::string sanitized = pbSession.playUrl;
            const size_t query = sanitized.find('?');
            if (query != std::string::npos) {
                sanitized = sanitized.substr(0, query) + "?<redacted>";
            }
            SoftLog(std::string("playerOpen method=") + jellyfin::player::PlayMethodToString(pbSession.method)
                    + " codec=" + pbSession.videoCodec
                    + " container=" + pbSession.container
                    + " profileFallback=" + (profileFallback ? "1" : "0")
                    + " url=" + sanitized);
        }

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
        "/Auth/Keys", "/Devices", "/Packages", "/Users/New", "/Users/Configuration",
        // 插件仓库：`GET /Repositories` 读、`POST /Repositories` 整体替换列表（PackageController）
        "/Repositories"
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

napi_value AdminGetLogText(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    ReadStringArg(env, info, 0, name);
    // 文件名由服务端按名字精确匹配（不是拼路径），这里只挡住明显不对的输入
    if (name.empty() || name.find('/') != std::string::npos || name.find("..") != std::string::npos) {
        return ToNapiJson(env, MakeResult(false, 400, "invalid log file name"));
    }
    int64_t keepTail = 0;
    ReadIntArg(env, info, 1, keepTail);
    const size_t tailBytes = keepTail > 0 ? static_cast<size_t>(keepTail) : 0;
    return RunAsync(env, [name, tailBytes]() {
        // 日志端点返回整份文件且服务端没有 range/tail 支持，所以只把结尾一段交给界面
        return FromApi(
                   Api().getTextTail(jellyfin::api::buildLogFileRequest(name).path, tailBytes))
            .dump();
    });
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

// ── 媒体库管理（设置 → 媒体库）──────────────────────────────────────────────
// 请求构造与响应归一化在 core 的 library_admin_api.{h,cpp} 里（纯函数，有主机单测）；
// 这里只做「取参数 → 构造请求 → 异步执行」的桥接，不拼 URL、不解析业务 JSON。
// 这些端点全部要求管理员权限（/Library/VirtualFolders/* 是 RequiresElevation）。

std::vector<std::string> JsonToStringVector(const nlohmann::json &value)
{
    std::vector<std::string> out;
    if (!value.is_array()) {
        return out;
    }
    for (const auto &item : value) {
        if (item.is_string()) {
            out.push_back(item.get<std::string>());
        }
    }
    return out;
}

std::string RunLibraryRequest(const jellyfin::api::LibraryRequest &request)
{
    return FromApi(jellyfin::api::execute(Api(), request)).dump();
}

napi_value LibraryVirtualFolders(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(jellyfin::api::getVirtualFolders(Api())).dump(); });
}

napi_value LibraryAvailableOptions(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string contentType;
    ReadStringArg(env, info, 0, contentType);
    bool isNewLibrary = false;
    ReadBoolArg(env, info, 1, isNewLibrary);
    return RunAsync(env, [contentType, isNewLibrary]() {
        const auto request =
            jellyfin::api::buildAvailableOptionsRequest(contentType, isNewLibrary);
        jellyfin::ApiResult result = jellyfin::api::execute(Api(), request);
        if (result.ok()) {
            result.data = jellyfin::api::normalizeAvailableOptions(result.data);
        }
        return FromApi(result).dump();
    });
}

napi_value LibraryLocalization(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() { return FromApi(jellyfin::api::getLocalization(Api())).dump(); });
}

napi_value LibraryAddVirtualFolder(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    std::string collectionType;
    std::string pathsJson;
    std::string optionsJson;
    bool refreshLibrary = true;
    ReadStringArg(env, info, 0, name);
    ReadStringArg(env, info, 1, collectionType);
    ReadStringArg(env, info, 2, pathsJson);
    ReadStringArg(env, info, 3, optionsJson);
    ReadBoolArg(env, info, 4, refreshLibrary);
    nlohmann::json paths;
    nlohmann::json options;
    ReadJsonArg(env, info, 2, paths);
    ReadJsonArg(env, info, 3, options);
    if (name.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library name is required"));
    }
    const std::vector<std::string> pathList = JsonToStringVector(paths);
    return RunAsync(env, [name, collectionType, pathList, options, refreshLibrary]() {
        return RunLibraryRequest(jellyfin::api::buildAddVirtualFolderRequest(
            name, collectionType, pathList, options, refreshLibrary));
    });
}

napi_value LibraryRenameVirtualFolder(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    std::string newName;
    bool refreshLibrary = false;
    ReadStringArg(env, info, 0, name);
    ReadStringArg(env, info, 1, newName);
    ReadBoolArg(env, info, 2, refreshLibrary);
    if (name.empty() || newName.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Both name and new name are required"));
    }
    return RunAsync(env, [name, newName, refreshLibrary]() {
        return RunLibraryRequest(
            jellyfin::api::buildRenameVirtualFolderRequest(name, newName, refreshLibrary));
    });
}

napi_value LibraryRemoveVirtualFolder(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    bool refreshLibrary = true;
    ReadStringArg(env, info, 0, name);
    ReadBoolArg(env, info, 1, refreshLibrary);
    if (name.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library name is required"));
    }
    return RunAsync(env, [name, refreshLibrary]() {
        return RunLibraryRequest(
            jellyfin::api::buildRemoveVirtualFolderRequest(name, refreshLibrary));
    });
}

napi_value LibraryAddMediaPath(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    std::string path;
    std::string networkPath;
    bool refreshLibrary = true;
    ReadStringArg(env, info, 0, name);
    ReadStringArg(env, info, 1, path);
    ReadStringArg(env, info, 2, networkPath);
    ReadBoolArg(env, info, 3, refreshLibrary);
    if (name.empty() || path.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library name and path are required"));
    }
    return RunAsync(env, [name, path, networkPath, refreshLibrary]() {
        return RunLibraryRequest(jellyfin::api::buildAddMediaPathRequest(
            name, path, networkPath, refreshLibrary));
    });
}

napi_value LibraryUpdateMediaPath(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    std::string path;
    std::string networkPath;
    ReadStringArg(env, info, 0, name);
    ReadStringArg(env, info, 1, path);
    ReadStringArg(env, info, 2, networkPath);
    if (name.empty() || path.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library name and path are required"));
    }
    return RunAsync(env, [name, path, networkPath]() {
        return RunLibraryRequest(
            jellyfin::api::buildUpdateMediaPathRequest(name, path, networkPath));
    });
}

napi_value LibraryRemoveMediaPath(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string name;
    std::string path;
    bool refreshLibrary = true;
    ReadStringArg(env, info, 0, name);
    ReadStringArg(env, info, 1, path);
    ReadBoolArg(env, info, 2, refreshLibrary);
    if (name.empty() || path.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library name and path are required"));
    }
    return RunAsync(env, [name, path, refreshLibrary]() {
        return RunLibraryRequest(
            jellyfin::api::buildRemoveMediaPathRequest(name, path, refreshLibrary));
    });
}

napi_value LibraryUpdateOptions(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string itemId;
    std::string optionsJson;
    nlohmann::json options;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, optionsJson);
    if (!ReadJsonArg(env, info, 1, options)) {
        return ToNapiJson(env, MakeResult(false, 400, "Library options JSON is required"));
    }
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library item id is required"));
    }
    return RunAsync(env, [itemId, options]() {
        return RunLibraryRequest(
            jellyfin::api::buildUpdateLibraryOptionsRequest(itemId, options));
    });
}

napi_value LibraryScanAll(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() {
        return RunLibraryRequest(jellyfin::api::buildRefreshLibraryRequest());
    });
}

napi_value LibraryScanFolder(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string itemId;
    std::string metadataRefreshMode;
    std::string imageRefreshMode;
    bool replaceAllMetadata = false;
    bool replaceAllImages = false;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, metadataRefreshMode);
    ReadStringArg(env, info, 2, imageRefreshMode);
    ReadBoolArg(env, info, 3, replaceAllMetadata);
    ReadBoolArg(env, info, 4, replaceAllImages);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library item id is required"));
    }
    return RunAsync(env, [itemId, metadataRefreshMode, imageRefreshMode, replaceAllMetadata,
                          replaceAllImages]() {
        return RunLibraryRequest(jellyfin::api::buildRefreshItemRequest(
            itemId, metadataRefreshMode, imageRefreshMode, replaceAllMetadata, replaceAllImages));
    });
}

// ── 媒体库封面（图片）───────────────────────────────────────────────────────
// 与其它 library* 一样：这里只接线，路径与 query 的构造在 core 的 library_admin_api，
// 由主机单测逐字断言（尤其是 imageUrl 里带 & 的图床地址必须被编码）。

napi_value LibraryCoverInfo(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string itemId;
    ReadStringArg(env, info, 0, itemId);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library item id is required"));
    }
    return RunAsync(env, [itemId]() {
        return RunLibraryRequest(jellyfin::api::buildItemImagesRequest(itemId));
    });
}

napi_value LibrarySetCoverFromUrl(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string itemId;
    std::string imageType;
    std::string imageUrl;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, imageType);
    ReadStringArg(env, info, 2, imageUrl);
    if (itemId.empty() || imageUrl.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library item id and image url are required"));
    }
    return RunAsync(env, [itemId, imageType, imageUrl]() {
        return RunLibraryRequest(jellyfin::api::buildRemoteImageDownloadRequest(
            itemId, imageType, imageUrl));
    });
}

napi_value LibraryDeleteCover(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string itemId;
    std::string imageType;
    int64_t imageIndex = -1;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, imageType);
    ReadIntArg(env, info, 2, imageIndex);
    if (itemId.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "Library item id is required"));
    }
    return RunAsync(env, [itemId, imageType, imageIndex]() {
        return RunLibraryRequest(jellyfin::api::buildDeleteItemImageRequest(
            itemId, imageType, static_cast<int>(imageIndex)));
    });
}

napi_value LibraryServerConfig(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() {
        jellyfin::ApiResult result =
            jellyfin::api::execute(Api(), jellyfin::api::buildServerConfigurationRequest());
        if (result.ok()) {
            result.data = jellyfin::api::normalizeServerConfiguration(result.data);
        }
        return FromApi(result).dump();
    });
}

napi_value LibraryMetadataSettings(napi_env env, napi_callback_info /*info*/)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    return RunAsync(env, []() {
        return FromApi(jellyfin::api::getMetadataSettings(Api())).dump();
    });
}

napi_value LibraryNamedConfig(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string key;
    ReadStringArg(env, info, 0, key);
    if (key.empty()) {
        return ToNapiJson(env, MakeResult(false, 400, "configuration key is required"));
    }
    // key 由本工程自己写死（`xbmcmetadata` 等），不接受页面传入任意字符串：
    // 走的是 `/System/Configuration/{key}`，key 会拼进路径
    if (key.find('/') != std::string::npos || key.find("..") != std::string::npos) {
        return ToNapiJson(env, MakeResult(false, 400, "invalid configuration key"));
    }
    return RunAsync(env, [key]() {
        return RunLibraryRequest(jellyfin::api::buildNamedConfigurationRequest(key));
    });
}

napi_value LibraryUpdateNamedConfig(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    std::string key;
    nlohmann::json configuration;
    ReadStringArg(env, info, 0, key);
    if (key.empty() || key.find('/') != std::string::npos || key.find("..") != std::string::npos) {
        return ToNapiJson(env, MakeResult(false, 400, "invalid configuration key"));
    }
    if (!ReadJsonArg(env, info, 1, configuration) || !configuration.is_object()) {
        return ToNapiJson(env, MakeResult(false, 400, "configuration JSON is required"));
    }
    return RunAsync(env, [key, configuration]() {
        return RunLibraryRequest(
            jellyfin::api::buildUpdateNamedConfigurationRequest(key, configuration));
    });
}

napi_value LibraryUpdateServerConfig(napi_env env, napi_callback_info info)
{
    const nlohmann::json guard = RequireAdmin();
    if (!guard.is_null()) {
        return ToNapiJson(env, guard);
    }
    nlohmann::json configuration;
    if (!ReadJsonArg(env, info, 0, configuration) || !configuration.is_object()) {
        return ToNapiJson(env, MakeResult(false, 400, "Server configuration JSON is required"));
    }
    return RunAsync(env, [configuration]() {
        return RunLibraryRequest(
            jellyfin::api::buildUpdateServerConfigurationRequest(configuration));
    });
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

/**
 * 构造外挂字幕地址（播放中切换字幕用）。
 *
 * 参数：itemId, mediaSourceId, streamIndex（Jellyfin MediaStreams[].Index）, codec
 * 返回：{ ok, data: { url, format, imageSubtitle } }
 *
 * 为什么由原生构造：服务器地址、访问令牌与 URL 形态属于 Jellyfin 集成细节，
 * ArkTS 侧不应自行拼接（见 AGENTS.md 的分层约定）。
 */
napi_value SubtitleUrl(napi_env env, napi_callback_info info)
{
    std::string itemId;
    std::string mediaSourceId;
    std::string codec;
    int64_t streamIndex = -1;
    ReadStringArg(env, info, 0, itemId);
    ReadStringArg(env, info, 1, mediaSourceId);
    ReadIntArg(env, info, 2, streamIndex);
    ReadStringArg(env, info, 3, codec);
    if (itemId.empty() || streamIndex < 0) {
        return ToNapiJson(env, MakeResult(false, 0, "itemId and streamIndex required"));
    }
    auto &session = jellyfin::SessionManager::instance();
    const std::string format = jellyfin::SubtitleFormatForCodec(codec);
    const std::string url = jellyfin::BuildSubtitleUrl(
        session.baseUrl(), itemId, mediaSourceId, static_cast<int>(streamIndex), format,
        session.accessToken());
    if (url.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "Unable to build subtitle url"));
    }
    nlohmann::json data = {
        {"url", url},
        {"format", format},
        {"codec", codec},
        {"imageSubtitle", jellyfin::IsImageSubtitleCodec(codec)},
    };
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
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

/**
 * 配置 HTTPS 用的 CA 根证书 PEM 路径（应用自带 Mozilla CA bundle，脱机可用）。
 * 未配置时 https 连接会明确失败（TLS 层要求校验证书与主机名），不会静默跳过校验。
 */
napi_value SetCaBundlePath(napi_env env, napi_callback_info info)
{
    std::string path;
    ReadStringArg(env, info, 0, path);
    if (path.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "path required"));
    }
    const bool ok = jellyfin::TlsSession::SetCaBundlePath(path);
    nlohmann::json data = {
        {"path", path},
        {"loaded", ok},
    };
    if (!ok) {
        return ToNapiJson(env, MakeResult(false, 0, "CA bundle 解析失败（文件缺失或不是 PEM）", data));
    }
    return ToNapiJson(env, MakeResult(true, 200, "ok", data));
}

/** 查询 CA 根证书是否已加载（诊断用） */
napi_value HasCaBundle(napi_env env, napi_callback_info /*info*/)
{
    return ToNapiJson(env, MakeResult(true, 200, "ok",
                                     nlohmann::json{{"loaded", jellyfin::TlsSession::HasCaBundle()}}));
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

/**
 * 取**字幕文本**（供应用侧自行解析并渲染）。
 *
 * 为什么需要它（设备实测的根因，**这是"字幕无法使用"的真正原因**）：
 * HarmonyOS 的 `AVPlayer.addSubtitleFromUrl()` 官方契约是
 *   "the external subtitle must be set **after fdSrc** of the video resource is set"
 * （见 SDK 的 `@ohos.multimedia.media.d.ts`，API 12 起就有该约束）。
 * 而本工程的播放走的是 `avPlayer.url = <网络地址>`，**不是 `fdSrc`** ——
 * 因此 `addSubtitleFromUrl` 是个**静默空操作**：Promise 正常 resolve（所以上层以为"已加载"），
 * 但播放器**根本不去取那个 URL**（服务端日志可证：客户端从未发出字幕请求），
 * 也不推 `subtitleUpdate` 事件 → 画面上永远没有字幕。
 * 另外 `MediaSource`（`setMediaSource` 的入参）只提供 `setMimeType` /
 * `enableOfflineCache` / `setMediaResourceLoaderDelegate`，**没有字幕字段**，
 * 所以换成 `setMediaSource` 也解决不了外挂字幕。
 *
 * 因此改为：由应用自己把字幕文本取回来，自行解析时间轴并按播放位置渲染
 * （播放页本来就有 `subtitleText` 的自绘路径，原生 SURFACE 上也画不了文本）。
 *
 * 安全约束：只接受**当前 Jellyfin 服务器**下的地址（同源校验），
 * 避免这个接口被当成任意 URL 抓取器。
 */
napi_value FetchSubtitleText(napi_env env, napi_callback_info info)
{
    std::string url;
    ReadStringArg(env, info, 0, url);
    if (url.empty()) {
        return ToNapiJson(env, MakeResult(false, 0, "url required"));
    }
    auto &session = jellyfin::SessionManager::instance();
    if (!session.isAuthenticated()) {
        return ToNapiJson(env, MakeResult(false, 401, "Not authenticated"));
    }
    const std::string base = session.baseUrl();
    if (base.empty() || url.rfind(base, 0) != 0) {
        return ToNapiJson(env, MakeResult(false, 0, "url must belong to the configured server"));
    }
    return RunAsync(env, [url]() {
        jellyfin::HttpClient http;
        const jellyfin::HttpResponse resp = http.get(url, {});
        if (!resp.error.empty()) {
            return MakeResult(false, 0, resp.error).dump();
        }
        if (resp.status != 200) {
            return MakeResult(false, resp.status,
                              "subtitle fetch failed with HTTP " + std::to_string(resp.status))
                .dump();
        }
        return MakeResult(true, 200, "ok", nlohmann::json{{"text", resp.body}}).dump();
    });
}

} // namespace

napi_value jellyfin_napi_init(napi_env env, napi_value exports)
{
    // 提升进程 fd 软上限到硬上限（设备实测硬上限为 32768）。
    //
    // 为什么需要：musl FORTIFY 的 `__fd_chk` 会用**进程启动时的 fd 上限**校验，
    // 而应用实际 fd 数在大图库/多图并发加载时会轻易超过较小的初始上限（实测 fd 涨到 1053
    // 后立刻 SIGABRT：`__fd_chk` → `__fortify_error` → abort）。把软上限提到硬上限后，
    // 合法 fd 不再被误判为非法；同时我们仍应限制并发请求数（见 ImageCache 的并发控制计划）。
    struct rlimit fdLimit {};
    if (getrlimit(RLIMIT_NOFILE, &fdLimit) == 0 && fdLimit.rlim_cur < fdLimit.rlim_max) {
        struct rlimit raised {};
        raised.rlim_cur = fdLimit.rlim_max;
        raised.rlim_max = fdLimit.rlim_max;
        if (setrlimit(RLIMIT_NOFILE, &raised) == 0) {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "jellyfin",
                         "raised fd limit %{public}llu -> %{public}llu",
                         static_cast<unsigned long long>(fdLimit.rlim_cur),
                         static_cast<unsigned long long>(raised.rlim_cur));
        }
    }
    napi_property_descriptor desc[] = {
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"configureServer", nullptr, ConfigureServer, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setDeviceId", nullptr, SetDeviceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playerSoftDecodeProbe", nullptr, PlayerSoftDecodeProbe, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"softPlayOpen", nullptr, SoftPlayOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"softPlayInitRenderer", nullptr, SoftPlayInitRenderer, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"softPlayNextFrame", nullptr, SoftPlayNextFrame, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"softPlayRenderLast", nullptr, SoftPlayRenderLast, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"softPlayStatus", nullptr, SoftPlayStatus, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"softPlayClose", nullptr, SoftPlayClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"softPlaySeek", nullptr, SoftPlaySeek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"softPlaySetScale", nullptr, SoftPlaySetScale, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"softPlayDumpFrame", nullptr, SoftPlayDumpFrame, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"softPlaySelfTest", nullptr, SoftPlaySelfTest, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"renderTargetProbe", nullptr, RenderTargetProbe, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getXComponentTouchEvent", nullptr, GetXComponentTouchEvent, nullptr, nullptr, nullptr,
         napi_default, nullptr},
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
        {"getNextUpForSeries", nullptr, GetNextUpForSeries, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getPlaybackInfo", nullptr, GetPlaybackInfo, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"toggleFavorite", nullptr, ToggleFavorite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"togglePlayed", nullptr, TogglePlayed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getUserItemData", nullptr, GetUserItemData, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getUserById", nullptr, GetUserById, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getUserViews", nullptr, GetUserViews, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"patchUserConfiguration", nullptr, PatchUserConfiguration, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"searchHints", nullptr, SearchHints, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPlaylists", nullptr, GetPlaylists, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createPlaylist", nullptr, CreatePlaylist, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"addToPlaylist", nullptr, AddToPlaylist, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getPlaylistItems", nullptr, GetPlaylistItems, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"removeFromPlaylist", nullptr, RemoveFromPlaylist, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"movePlaylistItem", nullptr, MovePlaylistItem, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"deletePlaylist", nullptr, DeletePlaylist, nullptr, nullptr, nullptr, napi_default,
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
        // 日志文件正文：只取结尾一段（服务端返回整份文件，且没有 range/tail 支持）
        {"adminGetLogText", nullptr, AdminGetLogText, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericGet", nullptr, AdminGenericGet, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericPost", nullptr, AdminGenericPost, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"adminGenericPostNoBody", nullptr, AdminGenericPostNoBody, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"adminGenericDelete", nullptr, AdminGenericDelete, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        // 媒体库管理（设置 → 媒体库）：端点与参数含义见 core/api/library_admin_api.h
        {"libraryVirtualFolders", nullptr, LibraryVirtualFolders, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryAvailableOptions", nullptr, LibraryAvailableOptions, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryLocalization", nullptr, LibraryLocalization, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryAddVirtualFolder", nullptr, LibraryAddVirtualFolder, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryRenameVirtualFolder", nullptr, LibraryRenameVirtualFolder, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryRemoveVirtualFolder", nullptr, LibraryRemoveVirtualFolder, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryAddMediaPath", nullptr, LibraryAddMediaPath, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryUpdateMediaPath", nullptr, LibraryUpdateMediaPath, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryRemoveMediaPath", nullptr, LibraryRemoveMediaPath, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryUpdateOptions", nullptr, LibraryUpdateOptions, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryScanAll", nullptr, LibraryScanAll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"libraryScanFolder", nullptr, LibraryScanFolder, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"libraryCoverInfo", nullptr, LibraryCoverInfo, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"librarySetCoverFromUrl", nullptr, LibrarySetCoverFromUrl, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryDeleteCover", nullptr, LibraryDeleteCover, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"libraryServerConfig", nullptr, LibraryServerConfig, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryUpdateServerConfig", nullptr, LibraryUpdateServerConfig, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryMetadataSettings", nullptr, LibraryMetadataSettings, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"libraryNamedConfig", nullptr, LibraryNamedConfig, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"libraryUpdateNamedConfig", nullptr, LibraryUpdateNamedConfig, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setPreference", nullptr, SetPreference, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPreferences", nullptr, GetPreferences, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getImageUrl", nullptr, GetImageUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"subtitleUrl", nullptr, SubtitleUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fetchSubtitleText", nullptr, FetchSubtitleText, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setImageCacheDir", nullptr, SetImageCacheDir, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setCaBundlePath", nullptr, SetCaBundlePath, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"hasCaBundle", nullptr, HasCaBundle, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadImage", nullptr, LoadImage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearImageCache", nullptr, ClearImageCache, nullptr, nullptr, nullptr, napi_default,
         nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    // 官方 XComponent 原生渲染入口：ArkUI 会把 XComponent 的 OH_NativeXComponent 注入到本模块 exports
    // （前提：ArkTS 侧 XComponent 指定 libraryname 指向本模块）
    jellyfin::player::XComponentBridge::Register(env, exports);
    return exports;
}
