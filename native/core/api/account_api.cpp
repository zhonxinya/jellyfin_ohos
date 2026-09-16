#include "account_api.h"

namespace jellyfin {
namespace api {

ApiResult authenticateByName(JellyfinApiClient &client, const std::string &username,
                             const std::string &password)
{
    nlohmann::json body = {
        {"Username", username},
        {"Pw", password},
    };
    return client.postJson("/Users/AuthenticateByName", body);
}

ApiResult getCurrentUser(JellyfinApiClient &client)
{
    return client.getJson("/Users/Me");
}

ApiResult getUsers(JellyfinApiClient &client)
{
    return client.getJson("/Users");
}

ApiResult getPublicUsers(JellyfinApiClient &client)
{
    return client.getJson("/Users/Public");
}

ApiResult getUserById(JellyfinApiClient &client, const std::string &userId)
{
    return client.getJson("/Users/" + userId);
}

ApiResult updateUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                  const nlohmann::json &configuration)
{
    return client.postJson("/Users/Configuration?userId=" + userId, configuration);
}

} // namespace api
} // namespace jellyfin
