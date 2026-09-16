#include "system_api.h"

namespace jellyfin {
namespace api {

ApiResult getPublicSystemInfo(JellyfinApiClient &client)
{
    return client.getJson("/System/Info/Public");
}

} // namespace api
} // namespace jellyfin
