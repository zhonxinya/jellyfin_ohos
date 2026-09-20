/**
 * Host-side unit tests for DeviceProfile（客户端能力声明 → Jellyfin PlaybackInfo 的 DeviceProfile）。
 *
 * 为什么值得单测：它决定"服务端会不会把内容转码"。写错一点（比如把 av1 又放进直接播放列表）
 * 就会静默退回"直连 + 本机软解"这条慢路径，而这一点在设备上很难一眼看出来
 * （播放能出画面，只是慢/无音频）。
 *
 * Build (from repo root):
 *   g++ -std=c++17 -I native/core -I native/third_party \
 *       native/core/tests/test_device_profile.cpp \
 *       native/core/api/device_profile.cpp \
 *       native/core/api/playback_api.cpp \
 *       native/core/api/playback_resolve.cpp \
 *       native/core/url_util.cpp -o test_device_profile
 */

#include "api/device_profile.h"
#include "api/playback_resolve.h"

#include <cstdio>
#include <string>

#include <nlohmann/json.hpp>

static int gFailed = 0;

static void expect(bool cond, const char *name, const std::string &detail = std::string())
{
    if (cond) {
        std::printf("ok   %s\n", name);
    } else {
        std::printf("FAIL %s%s%s\n", name, detail.empty() ? "" : " -> ", detail.c_str());
        ++gFailed;
    }
}

/** 在逗号分隔的编码串里找某个编码 */
static bool hasCodec(const std::string &list, const std::string &codec)
{
    std::string item;
    for (size_t i = 0; i <= list.size(); ++i) {
        if (i == list.size() || list[i] == ',') {
            if (item == codec) {
                return true;
            }
            item.clear();
        } else {
            item += list[i];
        }
    }
    return false;
}

static void testDefaultProfileExcludesAv1()
{
    using jellyfin::api::BuildDeviceProfile;
    using jellyfin::api::DefaultClientPlaybackCapabilities;

    const auto caps = DefaultClientPlaybackCapabilities();
    const nlohmann::json profile = BuildDeviceProfile(caps);

    expect(profile.contains("DirectPlayProfiles") && profile["DirectPlayProfiles"].is_array(),
           "DeviceProfile 含 DirectPlayProfiles 数组");

    std::string videoCodecs;
    std::string audioCodecs;
    std::string containers;
    for (const auto &entry : profile["DirectPlayProfiles"]) {
        if (entry.value("Type", "") == "Video") {
            videoCodecs = entry.value("VideoCodec", "");
            audioCodecs = entry.value("AudioCodec", "");
            containers = entry.value("Container", "");
        }
    }

    expect(hasCodec(videoCodecs, "h264"), "h264 允许直接播放（系统硬解支持）");
    expect(hasCodec(videoCodecs, "hevc"), "hevc 允许直接播放（本机软解可解）");
    expect(!hasCodec(videoCodecs, "av1"),
           "**av1 不在直接播放列表里**（本机解不动：系统不支持 + 软解 720p 仅约 7fps 且无音频）");
    expect(!hasCodec(videoCodecs, "av01"), "av01 也不在直接播放列表里");
    expect(hasCodec(containers, "mkv") && hasCodec(containers, "mp4"),
           "常见容器（mkv/mp4）允许直接播放");
    expect(hasCodec(audioCodecs, "aac") && hasCodec(audioCodecs, "flac"),
           "常见音频（aac/flac）允许直接播放");
}

/**
 * 10-bit 视频必须被"拒绝直连"。
 *
 * 为什么这条值得单测：`h264`/`hevc` 是按**编码名**匹配的，不区分位深 —— 少了这条约束，
 * H.264 High 10 会被判成可直连，交给系统硬解后**画面花屏**（部分区域马赛克）。
 * 本测试守住的是"DeviceProfile 里确实下发了 VideoBitDepth 约束"这一件事。
 */
static void testCodecProfileLimitsVideoBitDepth()
{
    using jellyfin::api::BuildDeviceProfile;
    using jellyfin::api::DefaultClientPlaybackCapabilities;

    const auto caps = DefaultClientPlaybackCapabilities();
    expect(caps.maxVideoBitDepth == 8, "默认能力把直接播放的位深上限设为 8 bit");

    const nlohmann::json profile = BuildDeviceProfile(caps);
    expect(profile.contains("CodecProfiles") && profile["CodecProfiles"].is_array() &&
           !profile["CodecProfiles"].empty(),
           "DeviceProfile 含非空 CodecProfiles（否则服务端不检查位深）");

    bool found = false;
    for (const auto &cp : profile["CodecProfiles"]) {
        if (cp.value("Type", "") != "Video") {
            continue;
        }
        if (!cp.contains("Conditions") || !cp["Conditions"].is_array()) {
            continue;
        }
        for (const auto &cond : cp["Conditions"]) {
            if (cond.value("Property", "") == "VideoBitDepth") {
                found = true;
                expect(cond.value("Condition", "") == "LessThanEqual",
                       "位深条件用 LessThanEqual（大于上限即需转码）");
                expect(cond.value("Value", "") == "8", "位深上限值为 8");
                expect(cond.value("IsRequired", true) == false,
                       "IsRequired=false（不是硬性要求，仅在不满足时触发转码）");
            }
        }
    }
    expect(found, "**下发了 VideoBitDepth 条件**（10-bit 因此被转码，避免硬解花屏）");

    // 置 0 表示"不限制"：此时不应下发任何位深条件
    auto unlimited = caps;
    unlimited.maxVideoBitDepth = 0;
    const nlohmann::json p2 = BuildDeviceProfile(unlimited);
    expect(p2.contains("CodecProfiles") && p2["CodecProfiles"].empty(),
           "maxVideoBitDepth=0 时不声明位深条件（空 CodecProfiles）");
}

static void testTranscodingProfileIsHlsH264()
{
    using jellyfin::api::BuildDeviceProfile;
    using jellyfin::api::DefaultClientPlaybackCapabilities;

    const nlohmann::json profile = BuildDeviceProfile(DefaultClientPlaybackCapabilities());
    expect(profile.contains("TranscodingProfiles") && !profile["TranscodingProfiles"].empty(),
           "DeviceProfile 含 TranscodingProfiles");

    const auto &video = profile["TranscodingProfiles"][0];
    expect(video.value("Container", "") == "ts", "转码容器为 ts");
    expect(video.value("VideoCodec", "") == "h264", "转码视频编码为 h264（系统可硬解）");
    expect(video.value("AudioCodec", "") == "aac", "转码音频编码为 aac");
    expect(video.value("Protocol", "") == "hls", "转码协议为 hls（AVPlayer 原生支持）");
    expect(video.value("Context", "") == "Streaming", "转码 Context 为 Streaming");
    expect(profile.value("MaxStreamingBitrate", 0) > 0, "声明了 MaxStreamingBitrate（否则服务端可能压到很低码率）");
}

static void testPlayableUrlDetection()
{
    using jellyfin::api::playbackInfoHasPlayableUrl;

    nlohmann::json withTranscode = {
        {"ItemId", "item-1"},
        {"MediaSources", {{{"Id", "ms-1"}, {"TranscodingUrl", "/Videos/item-1/master.m3u8?x=1"}}}},
    };
    expect(playbackInfoHasPlayableUrl(withTranscode),
           "有 TranscodingUrl 时认为可播放（转码路径）");

    nlohmann::json withDirectStream = {
        {"ItemId", "item-1"},
        {"MediaSources", {{{"Id", "ms-1"}, {"DirectStreamUrl", "/Videos/item-1/stream.mkv?Static=false"}}}},
    };
    expect(playbackInfoHasPlayableUrl(withDirectStream),
           "有 DirectStreamUrl 时认为可播放（直接串流路径）");

    // Jellyfin 对"可直连"的条目实测**只返回 MediaSources + PlaySessionId**（没有任何 Url、
    // 也没有 ItemId），此时必须仍然算"可播放"（客户端自己拼静态流地址），否则每个直连条目
    // 都会多做一次 PlaybackInfo 重试（设备实测曾在普通 H.264 上出现 profileFallback=1）。
    nlohmann::json directOnly = {
        {"PlaySessionId", "ps-1"},
        {"MediaSources", {{{"Id", "ms-1"}, {"SupportsDirectPlay", true}}}},
    };
    expect(playbackInfoHasPlayableUrl(directOnly),
           "只有 SupportsDirectPlay 标记、没有任何 Url 时仍认为可播放（直连条目）");

    nlohmann::json transcodeOnly = {
        {"MediaSources", {{{"Id", "ms-1"}, {"SupportsTranscoding", true}}}},
    };
    expect(playbackInfoHasPlayableUrl(transcodeOnly),
           "只有 SupportsTranscoding 标记时认为可播放（之后会拿到转码地址）");

    nlohmann::json unplayable = {
        {"MediaSources", {{{"Id", "ms-1"},
                           {"SupportsDirectPlay", false},
                           {"SupportsDirectStream", false},
                           {"SupportsTranscoding", false}}}},
    };
    expect(!playbackInfoHasPlayableUrl(unplayable),
           "三条路都被服务端否掉时认为不可播放（触发去掉 DeviceProfile 重试）");

    nlohmann::json empty = {{"MediaSources", nlohmann::json::array()}};
    expect(!playbackInfoHasPlayableUrl(empty), "空 MediaSources 认为不可播放");

    nlohmann::json notObject = nlohmann::json::array();
    expect(!playbackInfoHasPlayableUrl(notObject), "非对象响应认为不可播放");
}

int main()
{
    std::printf("== DeviceProfile 主机单测 ==\n");
    testDefaultProfileExcludesAv1();
    testTranscodingProfileIsHlsH264();
    testCodecProfileLimitsVideoBitDepth();
    testPlayableUrlDetection();

    if (gFailed == 0) {
        std::printf("All device profile tests passed\n");
        return 0;
    }
    std::printf("%d test(s) failed\n", gFailed);
    return 1;
}
