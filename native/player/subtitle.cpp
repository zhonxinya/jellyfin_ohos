#include "subtitle.h"

namespace jellyfin {
namespace player {

bool SubtitleRenderer::loadTrack(const std::string &urlOrPath)
{
    if (urlOrPath.empty()) {
        return false;
    }
    // libass bind later — accept path for API completeness.
    track_ = urlOrPath;
    loaded_ = true;
    return true;
}

void SubtitleRenderer::clear()
{
    loaded_ = false;
    track_.clear();
}

std::vector<std::string> SubtitleRenderer::cuesAt(int64_t /*positionMs*/) const
{
    return {};
}

} // namespace player
} // namespace jellyfin
