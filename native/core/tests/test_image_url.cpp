#include "image_url.h"

#include <iostream>
#include <string>

namespace {

int gFailures = 0;

void ExpectTrue(const char *name, bool condition)
{
    if (!condition) {
        std::cerr << "FAIL: " << name << '\n';
        ++gFailures;
    }
}

void ExpectContains(const char *name, const std::string &actual, const std::string &part)
{
    if (actual.find(part) == std::string::npos) {
        std::cerr << "FAIL: " << name << " missing '" << part << "' in '" << actual << "'\n";
        ++gFailures;
    }
}

} // namespace

int main()
{
    const std::string url = jellyfin::BuildImageUrl("https://example.com", "item-1", "Primary", 300,
                                                    "tagA", "token123");
    ExpectContains("path", url, "/Items/item-1/Images/Primary");
    ExpectContains("maxWidth", url, "maxWidth=300");
    ExpectContains("tag", url, "tag=tagA");
    ExpectTrue("https base", url.rfind("https://example.com", 0) == 0);
    // 安全约定：取图 URL **不得**携带访问令牌（URL 会进服务端访问日志）。
    // 凭据改由 X-Emby-Authorization 请求头传递，见 native/core/auth_headers.h。
    ExpectTrue("no api_key in url", url.find("api_key") == std::string::npos);
    ExpectTrue("no token in url", url.find("token123") == std::string::npos);

    nlohmann::json item = {
        {"ImageTags", {{"Primary", "p1"}}},
        {"BackdropImageTags", {"b1"}},
    };
    ExpectTrue("primary tag", jellyfin::ExtractImageTag(item, "Primary") == "p1");
    ExpectTrue("backdrop tag", jellyfin::ExtractImageTag(item, "Backdrop") == "b1");

    if (gFailures == 0) {
        std::cout << "All image_url tests passed.\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed.\n";
    return 1;
}
