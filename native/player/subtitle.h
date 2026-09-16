#ifndef JELLYFIN_PLAYER_SUBTITLE_H
#define JELLYFIN_PLAYER_SUBTITLE_H

#include <cstdint>
#include <string>
#include <vector>

namespace jellyfin {
namespace player {

/**
 * Subtitle renderer stub for future libass integration.
 * No real ASS/SSA rendering until libass is vendored under third_party/.
 */
class SubtitleRenderer {
public:
    bool loadTrack(const std::string &urlOrPath);
    void clear();
    bool isLoaded() const { return loaded_; }
    const std::string &track() const { return track_; }

    /** Stub: returns empty bitmap/text cues. */
    std::vector<std::string> cuesAt(int64_t positionMs) const;

private:
    bool loaded_ = false;
    std::string track_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_SUBTITLE_H */
