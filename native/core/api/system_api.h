#ifndef JELLYFIN_CORE_API_SYSTEM_API_H
#define JELLYFIN_CORE_API_SYSTEM_API_H

#include "api_client.h"

namespace jellyfin {
namespace api {

ApiResult getPublicSystemInfo(JellyfinApiClient &client);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_SYSTEM_API_H */
