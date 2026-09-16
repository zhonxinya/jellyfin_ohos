#ifndef JELLYFIN_CORE_API_ACCOUNT_API_H
#define JELLYFIN_CORE_API_ACCOUNT_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult authenticateByName(JellyfinApiClient &client, const std::string &username,
                             const std::string &password);
ApiResult getCurrentUser(JellyfinApiClient &client);
ApiResult getUsers(JellyfinApiClient &client);
ApiResult getPublicUsers(JellyfinApiClient &client);
ApiResult getUserById(JellyfinApiClient &client, const std::string &userId);
ApiResult updateUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                  const nlohmann::json &configuration);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_ACCOUNT_API_H */
