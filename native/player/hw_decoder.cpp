#include "hw_decoder.h"

#include <algorithm>
#include <cctype>

namespace jellyfin {
namespace player {
namespace {

std::string Lower(std::string s)
{
    for (char &c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

} // namespace

bool HwDecoder::canDecode(const std::string &codec)
{
    const std::string c = Lower(codec);
    return c == "h264" || c == "avc" || c == "avc1" || c == "hevc" || c == "h265" || c == "hev1";
}

bool HwDecoder::start(const std::string &codec)
{
    // The system AVPlayer owns hardware decoding in the ArkTS surface path.
    // This native class has no codec/surface binding and must not report success.
    (void)codec;
    active_ = false;
    backend_.clear();
    codec_.clear();
    return false;
}

void HwDecoder::stop()
{
    active_ = false;
    backend_.clear();
    codec_.clear();
}

} // namespace player
} // namespace jellyfin
