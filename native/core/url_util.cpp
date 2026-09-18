#include "url_util.h"

#include <algorithm>
#include <cctype>

namespace jellyfin {
namespace {

std::string Trim(const std::string &s)
{
    auto notSpace = [](unsigned char ch) { return !std::isspace(ch); };
    auto begin = std::find_if(s.begin(), s.end(), notSpace);
    auto end = std::find_if(s.rbegin(), s.rend(), notSpace).base();
    if (begin >= end) {
        return {};
    }
    return std::string(begin, end);
}

std::string ToLowerAscii(std::string s)
{
    for (char &c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

} // namespace

std::string NormalizeBaseUrl(const std::string &input)
{
    std::string url = Trim(input);
    if (url.empty()) {
        return {};
    }

    // Lowercase scheme only.
    const auto schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos) {
        return {};
    }
    std::string scheme = ToLowerAscii(url.substr(0, schemeEnd));
    if (scheme != "http" && scheme != "https") {
        return {};
    }
    url = scheme + url.substr(schemeEnd);

    // Strip one or more trailing slashes, but keep "http://host/" as "http://host"
    // and keep bare origin without inventing a path. Root path "/" alone is not a
    // valid base after scheme; after host, trailing slash means origin root.
    while (url.size() > scheme.size() + 3 && url.back() == '/') {
        // Do not strip past scheme://
        const size_t authorityStart = scheme.size() + 3;
        if (url.size() <= authorityStart + 1) {
            break;
        }
        // If removing slash would leave empty path after host with no chars — always OK
        // to remove trailing slash except when URL is exactly "http:///" (invalid).
        url.pop_back();
    }

    return url;
}

bool IsHttpsUrl(const std::string &url)
{
    if (url.size() < 8) {
        return false;
    }
    return ToLowerAscii(url.substr(0, 8)) == "https://";
}

std::string JoinUrl(const std::string &baseUrl, const std::string &path)
{
    if (baseUrl.empty()) {
        return path;
    }
    if (path.empty()) {
        return baseUrl;
    }
    if (path[0] == '/') {
        return baseUrl + path;
    }
    return baseUrl + "/" + path;
}

std::string EncodeQueryComponent(const std::string &value)
{
    static const char *kHex = "0123456789ABCDEF";
    std::string out;
    out.reserve(value.size() * 3);
    for (unsigned char c : value) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else {
            // 空格编成 %20 而不是 '+'：Jellyfin 跑在 ASP.NET Core 上，
            // 它的 query 解析（`QueryStringEnumerable` → `Uri.UnescapeDataString`）
            // **不**把 '+' 当空格（那是表单编码的规则），
            // 而 %20 在两种解释下都会被还原成空格 —— 所以这里只用 %20。
            // 受影响的入参包括搜索词、媒体库路径（可能带空格）与日志文件名。
            out.push_back('%');
            out.push_back(kHex[c >> 4]);
            out.push_back(kHex[c & 0x0F]);
        }
    }
    return out;
}

} // namespace jellyfin
