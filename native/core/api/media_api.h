#ifndef JELLYFIN_CORE_API_MEDIA_API_H
#define JELLYFIN_CORE_API_MEDIA_API_H

#include "api_client.h"
#include "items_query.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult queryItems(JellyfinApiClient &client, const std::string &userId, const ItemsQuery &query);

ApiResult getItems(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                   int startIndex, int limit, const std::string &searchTerm = {},
                   const std::string &includeTypes = {});

ApiResult getResumeItems(JellyfinApiClient &client, const std::string &userId, int startIndex = 0,
                       int limit = 20);
ApiResult getLatest(JellyfinApiClient &client, const std::string &userId, int limit = 20,
                    const std::string &parentId = {});
ApiResult getNextUp(JellyfinApiClient &client, const std::string &userId, int startIndex = 0,
                    int limit = 20);
ApiResult getGenres(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                    int startIndex, int limit);
ApiResult getStudios(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                     int startIndex, int limit);
ApiResult getSuggestions(JellyfinApiClient &client, const std::string &userId,
                         const std::string &parentId, int limit = 20);
ApiResult getUpcomingEpisodes(JellyfinApiClient &client, const std::string &userId, int startIndex = 0,
                              int limit = 20);

ApiResult getItem(JellyfinApiClient &client, const std::string &userId, const std::string &itemId);
ApiResult getSeasons(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId);
ApiResult getEpisodes(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId,
                      const std::string &seasonId);
ApiResult getSimilar(JellyfinApiClient &client, const std::string &userId, const std::string &itemId,
                     int limit = 12);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_MEDIA_API_H */
