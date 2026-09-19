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
    // ── DeviceProfile：把"本机真的能播什么"告诉服务端 ────────────────────────
    // 不带它时服务端会假定客户端什么都能直接播放：本机解不了的编码（AV1）就会被
    // 判成"直接播放"，客户端只能退到软解（帧率极低且无音频）。带上之后，
    // 服务端会为这类内容返回 TranscodingUrl（HLS + H.264/AAC），由硬件解码播放。
    const ClientPlaybackCapabilities capabilities =
        options.includeDeviceProfile
            ? (options.capabilities.videoCodecs.empty() ? DefaultClientPlaybackCapabilities()
                                                        : options.capabilities)
            : ClientPlaybackCapabilities{};
    if (options.includeDeviceProfile) {
        body["DeviceProfile"] = BuildDeviceProfile(capabilities);
    }
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
