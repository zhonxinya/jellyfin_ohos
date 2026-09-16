#include "catalog_api.h"

#include <sstream>

namespace {
std::string EncodeQueryValue(const std::string &value)
{
    static const char *hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : value) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('%');
            out.push_back(hex[c >> 4]);
            out.push_back(hex[c & 0x0F]);
        }
    }
    return out;
}
}

namespace jellyfin {
namespace api {

ApiResult getUserViews(JellyfinApiClient &client, const std::string &userId)
{
    return client.getJson("/Users/" + userId + "/Views");
}

ApiResult getSearchHints(JellyfinApiClient &client, const std::string &userId,
                         const std::string &term, int limit)
{
    std::ostringstream path;
    path << "/Search/Hints?UserId=" << EncodeQueryValue(userId)
         << "&SearchTerm=" << EncodeQueryValue(term) << "&Limit=" << limit
         << "&IncludeItemTypes=Movie,Series,Episode,Audio,MusicAlbum";
    return client.getJson(path.str());
}

} // namespace api
} // namespace jellyfin
