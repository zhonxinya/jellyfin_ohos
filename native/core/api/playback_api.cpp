#include "playback_api.h"

namespace jellyfin {
namespace api {

ApiResult getPlaybackInfo(JellyfinApiClient &client, const std::string &itemId,
                          const std::string &userId)
{
    PlaybackInfoOptions defaults;
    return postPlaybackInfo(client, itemId, userId, defaults);
}

ApiResult postPlaybackInfo(JellyfinApiClient &client, const std::string &itemId,
                           const std::string &userId, const PlaybackInfoOptions &options)
{
    nlohmann::json body = {
        {"UserId", userId},
        {"AutoOpenLiveStream", true},
        {"EnableDirectPlay", options.enableDirectPlay},
        {"EnableDirectStream", options.enableDirectStream},
        {"EnableTranscoding", options.enableTranscoding},
        {"AllowVideoStreamCopy", true},
        {"AllowAudioStreamCopy", true},
    };
    if (options.audioStreamIndex >= 0) {
        body["AudioStreamIndex"] = options.audioStreamIndex;
    }
    if (options.subtitleStreamIndex >= 0) {
        body["SubtitleStreamIndex"] = options.subtitleStreamIndex;
    }
    if (options.maxStreamingBitrate > 0) {
        body["MaxStreamingBitrate"] = options.maxStreamingBitrate;
    }
    return client.postJson("/Items/" + itemId + "/PlaybackInfo", body);
}

ApiResult reportPlaybackStart(JellyfinApiClient &client, const nlohmann::json &body)
{
    return client.postJson("/Sessions/Playing", body);
}

ApiResult reportPlaybackProgress(JellyfinApiClient &client, const nlohmann::json &body)
{
    return client.postJson("/Sessions/Playing/Progress", body);
}

ApiResult reportPlaybackStopped(JellyfinApiClient &client, const nlohmann::json &body)
{
    return client.postJson("/Sessions/Playing/Stopped", body);
}

} // namespace api
} // namespace jellyfin
