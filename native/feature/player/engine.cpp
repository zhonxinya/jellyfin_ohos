#include "engine.h"

namespace jellyfin {
namespace player {

const char *PlayerStateToString(PlayerState state)
{
    switch (state) {
    case PlayerState::Idle:
        return "Idle";
    case PlayerState::Opening:
        return "Opening";
    case PlayerState::Ready:
        return "Ready";
    case PlayerState::Playing:
        return "Playing";
    case PlayerState::Paused:
        return "Paused";
    case PlayerState::Error:
        return "Error";
    case PlayerState::Stopped:
        return "Stopped";
    default:
        return "Idle";
    }
}

PlayerEngine &PlayerEngine::instance()
{
    static PlayerEngine engine;
    return engine;
}

bool PlayerEngine::open(const PlaybackSession &session, std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    state_ = PlayerState::Opening;
    session_ = session;
    positionTicks_ = 0;
    lastError_.clear();
    hw_.stop();
    ffmpeg_.close();
    subtitles_.clear();
    backend_.clear();
    requiresExternalRenderer_ = false;

    if (session.playUrl.empty()) {
        error = "Empty play URL";
        lastError_ = error;
        state_ = PlayerState::Error;
        return false;
    }

    bool opened = false;
    if (HwDecoder::canDecode(session.videoCodec) && hw_.start(session.videoCodec)) {
        // HW path selected; stream binding deferred to AVCodec integration.
        backend_ = hw_.backendName();
        opened = true;
    } else if (ffmpeg_.open(session.playUrl, session.videoCodec)) {
        backend_ = ffmpeg_.backendName();
        opened = true;
    }

    if (!opened) {
        error = "No real decoder backend available";
        lastError_ = error;
        state_ = PlayerState::Error;
        return false;
    }

    state_ = PlayerState::Ready;
    return true;
}

bool PlayerEngine::prepareExternalRenderer(const PlaybackSession &session, std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    state_ = PlayerState::Opening;
    session_ = session;
    positionTicks_ = 0;
    lastError_.clear();
    hw_.stop();
    ffmpeg_.close();
    subtitles_.clear();

    if (session.playUrl.empty()) {
        error = "Empty play URL";
        lastError_ = error;
        backend_.clear();
        requiresExternalRenderer_ = false;
        state_ = PlayerState::Error;
        return false;
    }

    // ArkTS owns AVPlayer lifecycle and decoder control for this session.
    backend_ = "system-avplayer";
    requiresExternalRenderer_ = true;
    state_ = PlayerState::Ready;
    return true;
}

bool PlayerEngine::play(std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (requiresExternalRenderer_) {
        error = "External renderer controls playback";
        return false;
    }
    if (state_ != PlayerState::Ready && state_ != PlayerState::Paused &&
        state_ != PlayerState::Playing) {
        error = "Player not ready";
        return false;
    }
    state_ = PlayerState::Playing;
    return true;
}

bool PlayerEngine::pause(std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (requiresExternalRenderer_) {
        error = "External renderer controls playback";
        return false;
    }
    if (state_ != PlayerState::Playing && state_ != PlayerState::Paused) {
        error = "Player not playing";
        return false;
    }
    state_ = PlayerState::Paused;
    return true;
}

bool PlayerEngine::seek(int64_t positionTicks, std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == PlayerState::Idle || state_ == PlayerState::Stopped ||
        state_ == PlayerState::Error) {
        error = "Cannot seek in current state";
        return false;
    }
    if (positionTicks < 0) {
        error = "Invalid seek position";
        return false;
    }
    positionTicks_ = positionTicks;
    return true;
}

bool PlayerEngine::stop(std::string &error)
{
    std::lock_guard<std::mutex> lock(mutex_);
    (void)error;
    hw_.stop();
    ffmpeg_.close();
    subtitles_.clear();
    backend_.clear();
    requiresExternalRenderer_ = false;
    positionTicks_ = 0;
    state_ = PlayerState::Stopped;
    return true;
}

PlayerState PlayerEngine::state() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return state_;
}

bool PlayerEngine::requiresExternalRenderer() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return requiresExternalRenderer_;
}

nlohmann::json PlayerEngine::toJson() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return nlohmann::json{
        {"state", PlayerStateToString(state_)},
        {"backend", backend_},
        {"itemId", session_.itemId},
        {"mediaSourceId", session_.mediaSourceId},
        {"playSessionId", session_.playSessionId},
        {"playMethod", PlayMethodToString(session_.method)},
        {"playUrl", session_.playUrl},
        {"videoCodec", session_.videoCodec},
        {"audioCodec", session_.audioCodec},
        {"positionTicks", positionTicks_},
        {"runtimeTicks", session_.runtimeTicks},
        {"error", lastError_},
        {"requiresExternalRenderer", requiresExternalRenderer_},
    };
}

} // namespace player
} // namespace jellyfin
