#include "user_items_api.h"

namespace jellyfin {
namespace api {

ApiResult getUserItemData(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    return client.getJson("/Users/" + userId + "/Items/" + itemId + "/UserData");
}

ApiResult markFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    (void)userId;
    return client.postJson("/UserFavoriteItems/" + itemId, nlohmann::json::object());
}

ApiResult unmarkFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    (void)userId;
    return client.deleteJson("/UserFavoriteItems/" + itemId);
}

ApiResult markPlayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    (void)userId;
    return client.postJson("/UserPlayedItems/" + itemId, nlohmann::json::object());
}

ApiResult markUnplayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    (void)userId;
    return client.deleteJson("/UserPlayedItems/" + itemId);
}

} // namespace api
} // namespace jellyfin
