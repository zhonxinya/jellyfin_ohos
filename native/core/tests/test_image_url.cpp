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
    ExpectContains("api_key", url, "api_key=token123");
    ExpectTrue("https base", url.rfind("https://example.com", 0) == 0);

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
