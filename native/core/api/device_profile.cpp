#include "device_profile.h"

namespace jellyfin {
namespace api {
namespace {

/** 把编码列表拼成 Jellyfin 要的逗号分隔串 */
std::string Join(const std::vector<std::string> &items)
{
    std::string out;
    for (const auto &item : items) {
        if (item.empty()) {
            continue;
        }
        if (!out.empty()) {
            out += ",";
        }
        out += item;
    }
    return out;
}

} // namespace

ClientPlaybackCapabilities DefaultClientPlaybackCapabilities()
{
    ClientPlaybackCapabilities caps;
    // 与 scripts/build_ffmpeg_ohos.sh 的 --enable-decoder 列表保持一致（见头文件说明）。
    // 顺序无所谓，Jellyfin 只做集合匹配。
    caps.videoCodecs = {
        "h264", "hevc", "h265", "mpeg2video", "mpeg4", "msmpeg4v3", "vc1", "wmv3",
        "vp8", "vp9", "theora", "flv", "mjpeg", "prores",
    };
    caps.audioCodecs = {
        "aac", "mp3", "ac3", "eac3", "dts", "truehd", "mlp", "flac", "opus",
        "vorbis", "alac", "pcm_s16le", "pcm_s24le", "pcm_bluray", "pcm_dvd", "pcm_f32le",
    };
    caps.containers = {
        "mp4", "m4v", "mov", "mkv", "webm", "ts", "mpegts", "avi", "flv", "asf",
        "ogg", "wav", "mp3", "flac",
    };
    return caps;
}

nlohmann::json BuildDeviceProfile(const ClientPlaybackCapabilities &caps)
{
    const std::string video = Join(caps.videoCodecs);
    const std::string audio = Join(caps.audioCodecs);
    const std::string container = Join(caps.containers);

    nlohmann::json profile = {
        {"Name", caps.name},
        {"MaxStreamingBitrate", caps.maxStreamingBitrate},
        {"MaxStaticBitrate", caps.maxStreamingBitrate},
    };

    // ── 直接播放 ────────────────────────────────────────────────────────────
    // 视频、音频各一条（Jellyfin 按 Type 匹配）。
    nlohmann::json directPlay = nlohmann::json::array();
    if (!video.empty() && !container.empty()) {
        directPlay.push_back({
            {"Container", container},
            {"Type", "Video"},
            {"VideoCodec", video},
            {"AudioCodec", audio},
        });
    }
    if (!audio.empty()) {
        directPlay.push_back({
            {"Container", "mp3,flac,aac,m4a,ogg,wav,opus"},
            {"Type", "Audio"},
            {"AudioCodec", audio},
        });
    }
    profile["DirectPlayProfiles"] = directPlay;

    // ── 转码目标 ────────────────────────────────────────────────────────────
    // HLS + TS 容器 + H.264/AAC：HarmonyOS 的 AVPlayer 对这条组合支持最好
    // （原生 HLS 播放，硬件解码），也是 Jellyfin 官方客户端的默认选择。
    // MinSegments=1：首片就能起播，缩短"点了转码要等好几秒"的观感；
    // BreakOnNonKeyFrames=false：允许服务端在非关键帧处切片，起播更快。
    nlohmann::json transcoding = nlohmann::json::array();
    nlohmann::json videoProfile = {
        {"Container", caps.transcodeContainer},
        {"Type", "Video"},
        {"VideoCodec", caps.transcodeVideoCodec},
        {"AudioCodec", caps.transcodeAudioCodec},
        {"Protocol", caps.transcodeProtocol},
        {"Context", "Streaming"},
        {"MinSegments", 1},
        {"BreakOnNonKeyFrames", false},
    };
    if (!caps.transcodeMaxAudioChannels.empty()) {
        videoProfile["MaxAudioChannels"] = caps.transcodeMaxAudioChannels;
    }
    transcoding.push_back(videoProfile);
    // 纯音频条目：转码成 mp3（AVPlayer 都支持；音乐场景不需要 HLS）
    transcoding.push_back({
        {"Container", "mp3"},
        {"Type", "Audio"},
        {"AudioCodec", "mp3"},
        {"Protocol", "http"},
        {"Context", "Streaming"},
        {"MaxAudioChannels", "2"},
    });
    profile["TranscodingProfiles"] = transcoding;

    // ── 字幕 ────────────────────────────────────────────────────────────────
    // 文本字幕一律声明 External：本工程播放页的字幕走
    // `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.vtt`（服务端转换成 VTT），
    // 由 AVPlayer 的 `addSubtitleFromUrl` 加载 —— 直接播放与转码场景都能用。
    // 图形字幕（pgs/dvdsub/dvb）**不声明**：本工程不支持（`IsImageSubtitleCodec` 会拒掉）。
    nlohmann::json subtitles = nlohmann::json::array();
    for (const char *format : {"srt", "subrip", "ass", "ssa", "vtt", "webvtt", "ttml", "dfxp", "mov_text"}) {
        subtitles.push_back({{"Format", format}, {"Method", "External"}});
    }
    profile["SubtitleProfiles"] = subtitles;

    // 不声明任何 CodecProfiles：本工程对 profile/level 没有额外约束，
    // 交给服务端按"编码能否直接播放"判断即可（声明空数组比不写更明确）。
    profile["CodecProfiles"] = nlohmann::json::array();

    return profile;
}

bool playbackInfoHasPlayableUrl(const nlohmann::json &playbackInfo)
{
    if (!playbackInfo.is_object() || !playbackInfo.contains("MediaSources") ||
        !playbackInfo["MediaSources"].is_array() || playbackInfo["MediaSources"].empty()) {
        return false;
    }
    const auto &source = playbackInfo["MediaSources"][0];
    if (!source.is_object()) {
        return false;
    }
    // ① 服务端直接给了地址（转码 / 直接串流）→ 可播放
    for (const char *key : {"TranscodingUrl", "DirectStreamUrl"}) {
        if (source.contains(key) && source[key].is_string() && !source[key].get<std::string>().empty()) {
            return true;
        }
    }
    // ② Jellyfin 对"可以直连"的条目**根本不返回任何 Url 字段**（实测响应只有
    //    MediaSources + PlaySessionId，连 ItemId 都没有），此时客户端会用
    //    `/Videos/{id}/stream?static=true` 自己拼地址 —— 所以此时**也算可播放**。
    //    判据用服务端的三面支持标记：任一为 true 就说明这条路走得通。
    //    （早期版本把"没有 URL"当成"不可播放"，结果每个直连条目都会多做一次
    //      PlaybackInfo 重试 —— 设备实测 `profileFallback=1` 出现在普通 H.264 上。）
    for (const char *key : {"SupportsDirectPlay", "SupportsDirectStream", "SupportsTranscoding"}) {
        if (source.contains(key) && source[key].is_boolean() && source[key].get<bool>()) {
            return true;
        }
    }
    // ③ 服务端既不给直连也不给转码：只有这时才认为"这个响应里没有可用地址"，
    //    调用方据此去掉 DeviceProfile 重试一次。
    return false;
}

} // namespace api
} // namespace jellyfin
