#include "playlist_api.h"

namespace jellyfin {
namespace api {

ApiResult createPlaylist(JellyfinApiClient &client, const std::string &userId,
                         const std::string &name, const std::string &itemId)
{
    nlohmann::json body = {
        {"Name", name},
        {"Ids", nlohmann::json::array({itemId})},
        {"UserId", userId},
        {"MediaType", "Video"},
    };
    return client.postJson("/Playlists", body);
}

ApiResult addToPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                        const std::string &userId, const std::string &itemId)
{
    return client.postJson("/Playlists/" + playlistId + "/Items?Ids=" + itemId +
                               "&userId=" + userId,
                           nullptr);
}

ApiResult getPlaylists(JellyfinApiClient &client, const std::string &userId)
{
    return client.getJson("/Users/" + userId + "/Items?IncludeItemTypes=Playlist&Recursive=true");
}

} // namespace api
} // namespace jellyfin
