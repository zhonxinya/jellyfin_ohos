#include "account_api.h"

#include "json_arg.h"
#include "url_util.h"

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
    return client.getJson("/Users/" + EncodeQueryComponent(userId));
}

ApiResult updateUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                  const nlohmann::json &configuration)
{
    // 路由是 `{userId}/Configuration`（UserController 上的 [HttpPost("{userId}/Configuration")]）。
    // 旧实现写成 `/Users/Configuration?userId=…`：userId 落在路由段上被当成字面量 "Configuration"，
    // 服务端 Guid 绑定失败直接 400 —— 也就是说本应用里所有"用户设置"开关其实一直没保存成功过。
    return client.postJson("/Users/" + EncodeQueryComponent(userId) + "/Configuration",
                           configuration);
}

ApiResult patchUserConfiguration(JellyfinApiClient &client, const std::string &userId,
                                 const nlohmann::json &patch)
{
    if (!patch.is_object()) {
        ApiResult invalid;
        invalid.error.statusCode = 400;
        invalid.error.message = "configuration patch must be a JSON object";
        return invalid;
    }
    if (patch.empty()) {
        // 没有要改的字段就不发请求（也避免把一次无意义的整体替换发出去）
        return getUserById(client, userId);
    }

    ApiResult current = getUserById(client, userId);
    if (!current.ok()) {
        return current;
    }
    if (!current.data.is_object()) {
        ApiResult invalid;
        invalid.error.statusCode = 0;
        invalid.error.message = "unexpected user payload";
        return invalid;
    }

    // Configuration 可能是数组/字符串/null（服务端版本差异或异常响应），
    // 用 Object() 统一收敛成"拿不到对象就用空配置继续"——
    // 原来这里是 value(...) 再补一句 is_object() 判断，两处语义容易写岔。
    nlohmann::json config = jellyfin::json_arg::Object(current.data, "Configuration");
    for (auto it = patch.begin(); it != patch.end(); ++it) {
        config[it.key()] = it.value();
    }

    ApiResult result = updateUserConfiguration(client, userId, config);
    if (result.ok()) {
        result.data = config;
    }
    return result;
}

} // namespace api
} // namespace jellyfin
