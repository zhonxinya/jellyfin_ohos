#include "../api/playback_resolve.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include <nlohmann/json.hpp>

static int g_failed = 0;

static void expect(bool cond, const char *name)
{
    if (cond) {
        std::printf("ok   %s\n", name);
    } else {
        std::printf("FAIL %s\n", name);
        ++g_failed;
    }
}

int main()
{
    using jellyfin::api::resolvePlayUrl;
    using jellyfin::api::ProgressReporter;

    const std::string base = "http://192.168.1.10:8096";
    const std::string token = "tok";

    nlohmann::json withTranscode = {
        {"ItemId", "item-1"},
        {"MediaSources",
         nlohmann::json::array(
             {nlohmann::json{{"Id", "ms1"}, {"TranscodingUrl", "/videos/transcode.m3u8"}}})}};
    const std::string u1 = resolvePlayUrl(base, token, withTranscode);
    expect(u1.find("/videos/transcode.m3u8") != std::string::npos, "prefer transcoding url");

    nlohmann::json direct = {
        {"ItemId", "item-2"},
        {"MediaSources", nlohmann::json::array({nlohmann::json{{"Id", "ms2"}}})}};
    const std::string u2 = resolvePlayUrl(base, token, direct);
    expect(u2.find("/Videos/item-2/stream") != std::string::npos, "static stream path");
    expect(u2.find("static=true") != std::string::npos, "static flag");
    expect(u2.find("api_key=tok") != std::string::npos, "api key appended");

    ProgressReporter reporter(std::chrono::seconds(10));
    expect(reporter.shouldReport(false, false), "first progress report");
    reporter.markReported(false);
    expect(!reporter.shouldReport(false, false), "throttled within interval");
    expect(reporter.shouldReport(true, false), "pause forces report");
    expect(reporter.shouldReport(false, true), "force flush");

    if (g_failed != 0) {
        std::printf("%d playback tests failed\n", g_failed);
        return 1;
    }
    std::printf("All playback policy tests passed\n");
    return 0;
}
