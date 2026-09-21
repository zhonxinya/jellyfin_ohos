#include "subtitle_url.h"

#include "url_util.h"

#include <algorithm>
#include <cctype>
#include <sstream>

namespace jellyfin {
namespace {

std::string ToLower(const std::string &in)
{
    std::string out = in;
    std::transform(out.begin(), out.end(), out.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return out;
}

} // namespace

bool IsImageSubtitleCodec(const std::string &codec)
{
    const std::string c = ToLower(codec);
    return c == "pgssub" || c == "hdmv_pgs_subtitle" || c == "pgs" || c == "sup" ||
           c == "dvdsub" || c == "dvd_subtitle" || c == "vobsub" || c == "dvbsub" ||
           c == "dvb_subtitle" || c == "xsub";
}

std::string SubtitleFormatForCodec(const std::string &codec)
{
    const std::string c = ToLower(codec);
    if (IsImageSubtitleCodec(c)) {
        // 图形字幕：服务端不能转文本，只能按原样取回
        return c == "hdmv_pgs_subtitle" ? "sup" : c;
    }
    // 文本字幕：一律请求 WebVTT（兼容性最好，且服务端转换成本最低）
    return "vtt";
}

std::string BuildSubtitleUrl(const std::string &baseUrl, const std::string &itemId,
                             const std::string &mediaSourceId, int streamIndex,
                             const std::string &format, const std::string & /*accessToken*/)
{
    if (baseUrl.empty() || itemId.empty() || streamIndex < 0) {
        return {};
    }
    const std::string source = mediaSourceId.empty() ? itemId : mediaSourceId;
    const std::string fmt = format.empty() ? std::string("vtt") : ToLower(format);
    std::ostringstream path;
    path << "/Videos/" << itemId << "/" << source << "/Subtitles/" << streamIndex << "/Stream."
         << fmt;
    // 安全约定：不把访问令牌拼进 URL（URL 会进服务端访问日志）。
    // 字幕文本由本工程 HTTP 客户端拉取，凭据走 X-Emby-Authorization 头，
    // 见 native/napi FetchSubtitleText 与 core/auth_headers.h。
    return JoinUrl(baseUrl, path.str());
}

} // namespace jellyfin
