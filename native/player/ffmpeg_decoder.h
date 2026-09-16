#ifndef JELLYFIN_PLAYER_FFMPEG_DECODER_H
#define JELLYFIN_PLAYER_FFMPEG_DECODER_H

#include <string>

namespace jellyfin {
namespace player {

/**
 * Soft-decode fallback stub.
 * When JELLYFIN_HAS_FFMPEG is defined and linked, open() will use real FFmpeg.
 * Otherwise open() succeeds in soft-stub mode for integration testing.
 */
class FfmpegDecoder {
public:
    bool open(const std::string &url, const std::string &videoCodec = {});
    void close();
    bool isOpen() const { return open_; }
    const std::string &backendName() const { return backend_; }
    const std::string &url() const { return url_; }

private:
    bool open_ = false;
    std::string backend_;
    std::string url_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_FFMPEG_DECODER_H */
