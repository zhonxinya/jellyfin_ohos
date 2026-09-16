#ifndef JELLYFIN_PLAYER_PLAYBACK_POLICY_H
#define JELLYFIN_PLAYER_PLAYBACK_POLICY_H

#include <cstdint>
#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace player {

enum class PlayMethod {
    DirectPlay,
    DirectStream,
    Transcode,
    Unknown,
};

struct PlaybackSession {
    std::string itemId;
    std::string mediaSourceId;
    std::string playSessionId;
    std::string playUrl;
    std::string container;
    std::string videoCodec;
    std::string audioCodec;
    PlayMethod method = PlayMethod::Unknown;
    bool supportsDirectPlay = false;
    bool supportsDirectStream = false;
    bool supportsTranscoding = false;
    int64_t runtimeTicks = 0;
};

/** Resolve a playback session from /Items/{id}/PlaybackInfo JSON. */
bool ResolvePlaybackSession(const nlohmann::json &playbackInfo, const std::string &baseUrl,
                            const std::string &accessToken, PlaybackSession &out,
                            std::string &error);

const char *PlayMethodToString(PlayMethod method);

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_PLAYBACK_POLICY_H */
