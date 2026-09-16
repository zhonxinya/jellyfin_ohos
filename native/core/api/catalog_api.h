#ifndef JELLYFIN_CORE_API_CATALOG_API_H
#define JELLYFIN_CORE_API_CATALOG_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult getUserViews(JellyfinApiClient &client, const std::string &userId);
ApiResult getSearchHints(JellyfinApiClient &client, const std::string &userId,
                         const std::string &term, int limit = 12);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_CATALOG_API_H */
