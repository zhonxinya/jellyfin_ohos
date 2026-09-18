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

/**
 * 整体替换用户配置：`POST /Users/{userId}/Configuration`。
 *
 * ⚠️ 服务端 `UserManager.UpdateConfigurationAsync` 会把提交对象的**每个**字段都抄进用户记录，
 * 而反序列化一个"部分字段"的 JSON 会让其余字段变成 C# 构造函数默认值 ——
 * 所以**必须传完整配置对象**。只要想改一个字段，就用下面的 `patchUserConfiguration`。
 */
ApiResult updateUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                  const nlohmann::json &configuration);

/**
 * 只改若干字段：先 `GET /Users/{userId}` 取下当前 `Configuration`，
 * 把 `patch` 里的键合并进去，再整体提交。返回值 `data` 是合并后的配置对象。
 *
 * 为什么放在 core 而不是各页面里：GET-modify-POST 必须一次做完，
 * 页面里分散做既容易漏字段（部分提交会把没带的字段重置成默认值），又多一次往返竞态。
 */
ApiResult patchUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                 const nlohmann::json &patch);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_ACCOUNT_API_H */
