/**
 * Host-side unit tests for NormalizeBaseUrl.
 *
 * Build (from repo root):
 *   g++ -std=c++17 -I native/core native/core/tests/test_url_util.cpp native/core/url_util.cpp -o test_url_util
 *
 * Or run: scripts/run-native-core-tests.ps1
 */

#include "url_util.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int gFailures = 0;

void ExpectEq(const std::string &name, const std::string &got, const std::string &want)
{
    if (got != want) {
        std::cerr << "FAIL " << name << ": got=[" << got << "] want=[" << want << "]\n";
        ++gFailures;
    } else {
        std::cout << "ok   " << name << "\n";
    }
}

void ExpectTrue(const std::string &name, bool cond)
{
    if (!cond) {
        std::cerr << "FAIL " << name << "\n";
        ++gFailures;
    } else {
        std::cout << "ok   " << name << "\n";
    }
}

} // namespace

int main()
{
    using jellyfin::IsHttpsUrl;
    using jellyfin::JoinUrl;
    using jellyfin::NormalizeBaseUrl;

    ExpectEq("trim spaces", NormalizeBaseUrl("  http://192.168.1.10:8096  "),
             "http://192.168.1.10:8096");
    ExpectEq("strip trailing slash", NormalizeBaseUrl("http://host:8096/"), "http://host:8096");
    ExpectEq("keep proxy path", NormalizeBaseUrl("http://host/jellyfin/"), "http://host/jellyfin");
    ExpectEq("lowercase scheme", NormalizeBaseUrl("HTTP://HOST/path/"), "http://HOST/path");
    ExpectEq("https ok normalize", NormalizeBaseUrl("https://example.com/"), "https://example.com");
    ExpectEq("empty invalid", NormalizeBaseUrl(""), "");
    ExpectEq("no scheme", NormalizeBaseUrl("192.168.1.1:8096"), "");
    ExpectEq("ftp rejected", NormalizeBaseUrl("ftp://host/"), "");

    ExpectTrue("https detect", IsHttpsUrl("https://x"));
    ExpectTrue("http not https", !IsHttpsUrl("http://x"));

    ExpectEq("join absolute path", JoinUrl("http://h", "/Items"), "http://h/Items");
    ExpectEq("join relative path", JoinUrl("http://h", "Items"), "http://h/Items");

    if (gFailures != 0) {
        std::cerr << gFailures << " failure(s)\n";
        return EXIT_FAILURE;
    }
    std::cout << "All NormalizeBaseUrl tests passed\n";
    return EXIT_SUCCESS;
}
