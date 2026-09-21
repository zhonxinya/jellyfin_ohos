#include "image_url.h"

#include "url_util.h"

#include <sstream>

namespace jellyfin {

std::string BuildImageUrl(const std::string &baseUrl, const std::string &itemId,
                          const std::string &imageType, int maxWidth, const std::string &tag,
                          const std::string & /*accessToken*/)
{
    if (baseUrl.empty() || itemId.empty()) {
        return {};
    }
    const std::string type = imageType.empty() ? "Primary" : imageType;
    std::ostringstream path;
    path << "/Items/" << itemId << "/Images/" << type;
    std::ostringstream query;
    bool first = true;
    auto append = [&](const std::string &k, const std::string &v) {
        if (v.empty()) {
            return;
        }
        query << (first ? "?" : "&") << k << "=" << v;
        first = false;
    };
    if (maxWidth > 0) {
        append("maxWidth", std::to_string(maxWidth));
    }
    if (!tag.empty()) {
        append("tag", tag);
    }
    // 安全约定：**不把访问令牌拼进 URL**（旧实现追加 api_key=<token>）。
    // 原因：URL 会被 Jellyfin 写进服务端访问日志（设备实测曾出现 147 处 api_key=…），
    // 也会经 Referer/代理/浏览器历史等渠道外泄。取图统一由本工程 HTTP 客户端完成，
    // 凭据通过 `X-Emby-Authorization` 请求头传递（见 native/napi LoadImage）。
    return JoinUrl(baseUrl, path.str()) + query.str();
}

std::string ExtractImageTag(const nlohmann::json &item, const std::string &imageType)
{
    if (!item.is_object()) {
        return {};
    }
    if (item.contains("ImageTags") && item["ImageTags"].is_object()) {
        const auto &tags = item["ImageTags"];
        if (tags.contains(imageType) && tags[imageType].is_string()) {
            return tags[imageType].get<std::string>();
        }
        if (imageType == "Primary" && tags.contains("primary") && tags["primary"].is_string()) {
            return tags["primary"].get<std::string>();
        }
    }
    if (imageType == "Primary" && item.contains("PrimaryImageTag") &&
        item["PrimaryImageTag"].is_string()) {
        return item["PrimaryImageTag"].get<std::string>();
    }
    if (imageType == "Backdrop" && item.contains("BackdropImageTags") &&
        item["BackdropImageTags"].is_array() && !item["BackdropImageTags"].empty() &&
        item["BackdropImageTags"][0].is_string()) {
        return item["BackdropImageTags"][0].get<std::string>();
    }
    return {};
}

} // namespace jellyfin
