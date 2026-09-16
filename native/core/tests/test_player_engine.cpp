#include "../../player/engine.h"

#include <cstdio>
#include <string>

static int g_failed = 0;

static void expect(bool condition, const char *name)
{
    if (condition) {
        std::printf("ok   %s\n", name);
    } else {
        std::printf("FAIL %s\n", name);
        ++g_failed;
    }
}

int main()
{
    jellyfin::player::PlaybackSession session;
    session.itemId = "item-1";
    session.playUrl = "http://example.invalid/video.mp4";
    session.videoCodec = "h264";
    session.runtimeTicks = 90000000;

    auto &engine = jellyfin::player::PlayerEngine::instance();
    std::string error;
    expect(engine.prepareExternalRenderer(session, error), "prepare external renderer");
    const nlohmann::json prepared = engine.toJson();
    expect(prepared.value("backend", "") == "system-avplayer", "system AVPlayer backend");
    expect(prepared.value("requiresExternalRenderer", false), "external renderer required");
    expect(prepared.value("state", "") == "Ready", "external renderer ready state");

    error.clear();
    expect(!engine.play(error), "native play rejected for external renderer");
    expect(error.find("External renderer") != std::string::npos, "native play rejection explains ownership");

    error.clear();
    expect(!engine.pause(error), "native pause rejected for external renderer");
    error.clear();
    expect(engine.seek(10000, error), "native seek records sync position");
    expect(engine.toJson().value("positionTicks", -1LL) == 10000, "seek uses ticks");

    error.clear();
    expect(engine.stop(error), "stop external session");
    expect(!engine.toJson().value("requiresExternalRenderer", true), "stop clears external renderer mode");

    std::printf(g_failed == 0 ? "All player engine tests passed\\n" : "%d player engine tests failed\\n", g_failed);
    return g_failed == 0 ? 0 : 1;
}
