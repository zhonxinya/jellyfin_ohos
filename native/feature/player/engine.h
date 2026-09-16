#ifndef JELLYFIN_PLAYER_ENGINE_H
#define JELLYFIN_PLAYER_ENGINE_H

#include "ffmpeg_decoder.h"
#include "hw_decoder.h"
#include "playback_policy.h"
#include "subtitle.h"

#include <cstdint>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace player {

enum class PlayerState {
    Idle,
    Opening,
    Ready,
    Playing,
    Paused,
    Error,
    Stopped,
};

const char *PlayerStateToString(PlayerState state);

/**
 * PlayerEngine state machine for linked native decoder backends.
 * Playback URLs may instead be prepared for the ArkTS system AVPlayer without
 * opening a native decoder.
 */
class PlayerEngine {
public:
    static PlayerEngine &instance();

    bool open(const PlaybackSession &session, std::string &error);
    bool prepareExternalRenderer(const PlaybackSession &session, std::string &error);
    bool play(std::string &error);
    bool pause(std::string &error);
    bool seek(int64_t positionTicks, std::string &error);
    bool stop(std::string &error);

    PlayerState state() const;
    bool requiresExternalRenderer() const;
    nlohmann::json toJson() const;

private:
    PlayerEngine() = default;

    mutable std::mutex mutex_;
    PlayerState state_ = PlayerState::Idle;
    PlaybackSession session_;
    std::string backend_;
    std::string lastError_;
    bool requiresExternalRenderer_ = false;
    int64_t positionTicks_ = 0;
    HwDecoder hw_;
    FfmpegDecoder ffmpeg_;
    SubtitleRenderer subtitles_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_ENGINE_H */
