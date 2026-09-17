#ifndef JELLYFIN_CORE_API_CATALOG_API_H
#define JELLYFIN_CORE_API_CATALOG_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

ApiResult getUserViews(JellyfinApiClient &client, const std::string &userId);

/**
 * 搜索建议（`/Search/Hints`）。
 *
 * `parentId` 用于"库内搜索"（只给该库的建议）；`includeItemTypes` 用于按类型收窄
 * （不传则用默认类型集合）。
 */
ApiResult getSearchHints(JellyfinApiClient &client, const std::string &userId,
                         const std::string &term, int limit = 12,
                         const std::string &parentId = {},
                         const std::string &includeItemTypes = {});

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_CATALOG_API_H */
