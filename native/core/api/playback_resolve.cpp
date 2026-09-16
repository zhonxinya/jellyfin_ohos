#include "playback_resolve.h"

#include "url_util.h"

namespace jellyfin {
namespace api {

std::string resolvePlayUrl(const std::string &baseUrl, const std::string &accessToken,
                           const nlohmann::json &playbackInfo)
{
    if (!playbackInfo.is_object()) {
        return {};
    }
    const nlohmann::json *mediaSource = nullptr;
    if (playbackInfo.contains("MediaSources") && playbackInfo["MediaSources"].is_array() &&
        !playbackInfo["MediaSources"].empty()) {
        mediaSource = &playbackInfo["MediaSources"][0];
    }
    if (mediaSource == nullptr) {
        return {};
    }

    if (mediaSource->contains("TranscodingUrl") && (*mediaSource)["TranscodingUrl"].is_string()) {
        const std::string t = (*mediaSource)["TranscodingUrl"].get<std::string>();
        if (!t.empty()) {
            if (t.rfind("http://", 0) == 0 || t.rfind("https://", 0) == 0) {
                return t;
            }
            return JoinUrl(baseUrl, t);
        }
    }

    std::string mediaSourceId;
    if (mediaSource->contains("Id") && (*mediaSource)["Id"].is_string()) {
        mediaSourceId = (*mediaSource)["Id"].get<std::string>();
    }

    std::string itemId;
    if (playbackInfo.contains("ItemId") && playbackInfo["ItemId"].is_string()) {
        itemId = playbackInfo["ItemId"].get<std::string>();
    }

    if (itemId.empty()) {
        return {};
    }

    std::string path = "/Videos/" + itemId + "/stream?static=true";
    if (!mediaSourceId.empty()) {
        path += "&MediaSourceId=" + mediaSourceId;
    }
    if (!accessToken.empty()) {
        path += "&api_key=" + accessToken;
    }
    return JoinUrl(baseUrl, path);
}

ProgressReporter::ProgressReporter(std::chrono::seconds interval) : interval_(interval) {}

bool ProgressReporter::shouldReport(bool isPaused, bool force)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (force) {
        return true;
    }
    if (!hasLast_) {
        return true;
    }
    if (isPaused != lastPaused_) {
        return true;
    }
    const auto now = std::chrono::steady_clock::now();
    return (now - lastReport_) >= interval_;
}

void ProgressReporter::markReported(bool isPaused)
{
    std::lock_guard<std::mutex> lock(mutex_);
    lastReport_ = std::chrono::steady_clock::now();
    hasLast_ = true;
    lastPaused_ = isPaused;
}

void ProgressReporter::reset()
{
    std::lock_guard<std::mutex> lock(mutex_);
    hasLast_ = false;
}

} // namespace api
} // namespace jellyfin
