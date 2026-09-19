#ifndef JELLYFIN_CORE_API_PLAYBACK_API_H
#define JELLYFIN_CORE_API_PLAYBACK_API_H

#include "api_client.h"
#include "device_profile.h"
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
    /**
     * 是否随请求带上 `DeviceProfile`（默认带）。
     *
     * 带：服务端知道本机**不能**直接播的编码（当前是 AV1），会返回 TranscodingUrl 转码播放。
     * 不带：服务端假定"什么都能直连"（本工程改造前的行为）。
     * 保底路径：带了 DeviceProfile 却拿不到任何可用 URL（服务端没装/没开转码）时，
     * 调用方应把这一项置 false 重试一次 —— 退回直连 + 本机软解，而不是报错。
     */
    bool includeDeviceProfile = true;
    /** 设备能力（仅在 includeDeviceProfile=true 时使用） */
    ClientPlaybackCapabilities capabilities;
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
