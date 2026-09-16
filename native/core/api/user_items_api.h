#ifndef JELLYFIN_CORE_API_USER_ITEMS_API_H
#define JELLYFIN_CORE_API_USER_ITEMS_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult getUserItemData(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);
ApiResult markFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);
ApiResult unmarkFavorite(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);
ApiResult markPlayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);
ApiResult markUnplayed(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_USER_ITEMS_API_H */
