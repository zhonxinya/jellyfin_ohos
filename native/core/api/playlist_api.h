#ifndef JELLYFIN_CORE_API_PLAYLIST_API_H
#define JELLYFIN_CORE_API_PLAYLIST_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult createPlaylist(JellyfinApiClient &client, const std::string &userId,
                         const std::string &name, const std::string &itemId);
ApiResult addToPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                        const std::string &userId, const std::string &itemId);
ApiResult getPlaylists(JellyfinApiClient &client, const std::string &userId);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_PLAYLIST_API_H */
