#ifndef JELLYFIN_CORE_API_PLAYBACK_API_H
#define JELLYFIN_CORE_API_PLAYBACK_API_H

#include "api_client.h"
#include "playback_resolve.h"

#include <string>

namespace jellyfin {
namespace api {

struct PlaybackInfoOptions {
    int audioStreamIndex = -1;
    int subtitleStreamIndex = -1;
    int maxStreamingBitrate = 0;
    bool enableDirectPlay = true;
    bool enableDirectStream = true;
    bool enableTranscoding = true;
};

ApiResult getPlaybackInfo(JellyfinApiClient &client, const std::string &itemId,
                          const std::string &userId);
ApiResult postPlaybackInfo(JellyfinApiClient &client, const std::string &itemId,
                           const std::string &userId, const PlaybackInfoOptions &options);
ApiResult reportPlaybackStart(JellyfinApiClient &client, const nlohmann::json &body);
ApiResult reportPlaybackProgress(JellyfinApiClient &client, const nlohmann::json &body);
ApiResult reportPlaybackStopped(JellyfinApiClient &client, const nlohmann::json &body);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_PLAYBACK_API_H */
