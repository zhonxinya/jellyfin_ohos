#include "ffmpeg_decoder.h"

namespace jellyfin {
namespace player {

bool FfmpegDecoder::open(const std::string &url, const std::string & /*videoCodec*/)
{
    if (url.empty()) {
        return false;
    }
    url_ = url;

#if defined(JELLYFIN_HAS_FFMPEG)
    // Real FFmpeg demux/decode path will be linked here when the vendor tree
    // provides libavformat/libavcodec. Until then this branch is unused.
    backend_ = "ffmpeg";
    open_ = true;
    return true;
#else
    // FFmpeg is not linked in this build; do not claim that decoding is available.
    backend_.clear();
    open_ = false;
    return false;
#endif
}

void FfmpegDecoder::close()
{
    open_ = false;
    backend_.clear();
    url_.clear();
}

} // namespace player
} // namespace jellyfin
