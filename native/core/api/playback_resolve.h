#ifndef JELLYFIN_CORE_API_PLAYBACK_RESOLVE_H
#define JELLYFIN_CORE_API_PLAYBACK_RESOLVE_H

#include <chrono>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace api {

/**
 * Prefer MediaSource.TranscodingUrl; else build static stream URL.
 */
std::string resolvePlayUrl(const std::string &baseUrl, const std::string &accessToken,
                           const nlohmann::json &playbackInfo);

/**
 * Throttles progress reports to at most once per interval (default 10s).
 */
class ProgressReporter {
public:
    explicit ProgressReporter(std::chrono::seconds interval = std::chrono::seconds(10));
    bool shouldReport(bool isPaused, bool force = false);
    void markReported(bool isPaused);
    void reset();

private:
    std::chrono::seconds interval_;
    std::mutex mutex_;
    std::chrono::steady_clock::time_point lastReport_{};
    bool hasLast_ = false;
    bool lastPaused_ = false;
};

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_PLAYBACK_RESOLVE_H */
