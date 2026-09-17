#include "user_items_api.h"

#include "url_util.h"

namespace jellyfin {
namespace api {
namespace {

/**
 * 收藏 / 观看状态接口在 Jellyfin 版本之间**换过路由**，而且两套路由互不兼容：
 *
 * | 路由形态 | 10.8.x（本工程的目标服务器实测） | 10.10.x |
 * |---|---|---|
 * | `/Users/{userId}/FavoriteItems/{itemId}` | ✅ 200 | ❌ |
 * | `/UserFavoriteItems/{itemId}` | ❌ **404** | ✅ |
 *
 * 设备实测（服务器 `10.8.12`）：走旧路由 `POST /UserFavoriteItems/{id}` 返回 **404**，
 * 而界面只在成功时更新状态、又不显示失败原因 —— 用户看到的是"点了星标没反应"，
 * 即收藏与"标记已看"这两个功能在实际服务器上**整体失效**。
 *
 * 因此这里按"新式（带 userId）优先、404 时回退旧式"的顺序探测：
 * 两个版本都能用，且不依赖服务器版本号探测。
 */
bool IsNotFoundOrMethodNotAllowed(const ApiResult &result)
{
    // 404：路由不存在；405：路由存在但方法不对（`/Items/Suggestions` 在 10.8.12 上即 405）
    return result.error.statusCode == 404 || result.error.statusCode == 405;
}

ApiResult PostWithFallback(JellyfinApiClient &client, const std::string &primary,
                           const std::string &legacy)
{
    ApiResult result = client.postJson(primary, nlohmann::json::object());
    if (!result.ok() && IsNotFoundOrMethodNotAllowed(result)) {
        return client.postJson(legacy, nlohmann::json::object());
    }
    return result;
}

ApiResult DeleteWithFallback(JellyfinApiClient &client, const std::string &primary,
                             const std::string &legacy)
{
    ApiResult result = client.deleteJson(primary);
    if (!result.ok() && IsNotFoundOrMethodNotAllowed(result)) {
        return client.deleteJson(legacy);
    }
    return result;
}

std::string UserPath(const std::string &userId, const std::string &suffix)
{
    return "/Users/" + EncodeQueryComponent(userId) + "/" + suffix;
}

} // namespace

ApiResult getUserItemData(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    return client.getJson(UserPath(userId, "Items/" + EncodeQueryComponent(itemId) + "/UserData"));
}

ApiResult markFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    const std::string id = EncodeQueryComponent(itemId);
    return PostWithFallback(client, UserPath(userId, "FavoriteItems/" + id),
                            "/UserFavoriteItems/" + id);
}

ApiResult unmarkFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    const std::string id = EncodeQueryComponent(itemId);
    return DeleteWithFallback(client, UserPath(userId, "FavoriteItems/" + id),
                              "/UserFavoriteItems/" + id);
}

ApiResult markPlayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    const std::string id = EncodeQueryComponent(itemId);
    return PostWithFallback(client, UserPath(userId, "PlayedItems/" + id),
                            "/UserPlayedItems/" + id);
}

ApiResult markUnplayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    const std::string id = EncodeQueryComponent(itemId);
    return DeleteWithFallback(client, UserPath(userId, "PlayedItems/" + id),
                              "/UserPlayedItems/" + id);
}

} // namespace api
} // namespace jellyfin
