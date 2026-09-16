#ifndef JELLYFIN_PLAYER_HW_DECODER_H
#define JELLYFIN_PLAYER_HW_DECODER_H

#include <string>

namespace jellyfin {
namespace player {

/**
 * Hardware decoder stub. Real AVCodec binding comes later.
 * canDecode uses a simple codec-name heuristic (h264/avc/hevc/h265).
 */
class HwDecoder {
public:
    static bool canDecode(const std::string &codec);

    bool start(const std::string &codec);
    void stop();
    bool isActive() const { return active_; }
    const std::string &backendName() const { return backend_; }

private:
    bool active_ = false;
    std::string backend_;
    std::string codec_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_HW_DECODER_H */
