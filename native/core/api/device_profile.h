#ifndef JELLYFIN_CORE_API_DEVICE_PROFILE_H
#define JELLYFIN_CORE_API_DEVICE_PROFILE_H

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace api {

/**
 * 客户端播放能力 —— 用于构造 Jellyfin 的 `DeviceProfile`。
 *
 * 为什么必须有它（本工程此前的缺陷）：
 * `/Items/{id}/PlaybackInfo` 不带 `DeviceProfile` 时，服务端会**假定客户端什么都能直接播**，
 * 于是 AV1、10bit HEVC 之类本机解不了的内容也一律返回"直接播放"。客户端只能自己扛：
 * 硬解失败 → 回退 FFmpeg 软解（AV1 的软解路径在本工程里曾完全解不出帧，见
 * native/feature/player/README.md 的「AV1 软解」）。声明能力后，服务端会把这类内容
 * **转码**成客户端真正能播的 H.264/HLS，由硬件解码播放 —— 这才是移动端该有的做法。
 */
struct ClientPlaybackCapabilities {
    /** 直接播放的视频编码（**不含**服务端应转码的编码，例如 av1） */
    std::vector<std::string> videoCodecs;
    /** 直接播放的音频编码 */
    std::vector<std::string> audioCodecs;
    /** 直接播放的容器 */
    std::vector<std::string> containers;
    /**
     * 能直接播放的最高视频位深（bit）。
     *
     * 为什么必须单独声明（设备实测的"花屏"根因）：`videoCodecs` 里的 `h264` 是**按编码名**
     * 匹配的，不区分位深 —— 于是 **H.264 High 10（`yuv420p10le`，10-bit）** 也被判成"可直连"，
     * 交给系统硬解后画面**花屏**（部分区域呈马赛克）。
     * 服务端只在 `CodecProfiles` 的条件里才会检查位深，因此这里配套下发一条
     * `VideoBitDepth <= 8` 的约束，让 10-bit 走服务端转码成 8-bit 后再硬解。
     *
     * 0 = 不限制（不声明该条件）。
     */
    int maxVideoBitDepth = 8;
    /** 转码目标：容器 / 视频编码 / 音频编码 / 协议 */
    std::string transcodeContainer = "ts";
    std::string transcodeVideoCodec = "h264";
    std::string transcodeAudioCodec = "aac";
    std::string transcodeProtocol = "hls";
    /** 转码音频声道上限（"2" = 立体声，移动端最稳；空 = 不限） */
    std::string transcodeMaxAudioChannels = "2";
    /** 客户端可接受的最高码率（bps；0 = 不限）。服务端在这个上限内决定转码码率 */
    int maxStreamingBitrate = 120000000;
    /** 设备名（出现在服务端"设备"列表与 PlaybackInfo 里，便于排查） */
    std::string name = "Jellyfin HarmonyOS Native";
};

/**
 * 本工程的默认能力。
 *
 * 判定依据（都是实测，不是抄来的默认值）：
 *  - 视频编码白名单 = 本工程 FFmpeg 构建里**启用的解码器**（`scripts/build_ffmpeg_ohos.sh`
 *    的 `--enable-decoder` 列表）∩ 系统 AVPlayer 常见能力；这样"声明能播"与"真的能解"
 *    是对齐的，不会出现"声明了但解不了"。
 *  - **av1 故意不在白名单**：设备侧系统解码器普遍不支持 AV1；FFmpeg 软解改用 dav1d 后
 *    虽然能出帧，但 720p 在 x86 模拟器上只有约 7 fps（解码本身 38ms/帧，其余是
 *    swscale + 纹理上传 + NAPI 往返），1080p/4K 更差，且软解路径**没有音频输出**。
 *    交给服务端转码成 H.264 后可以走硬件解码，帧率与音频都正常。
 *    需要在"服务器不能转码"的场景下仍然能播 AV1 时，见 postPlaybackInfo 的
 *    `includeDeviceProfile=false` 重试路径（退回直连 + 本机软解）。
 *  - **10-bit 视频不直接播放**（`maxVideoBitDepth = 8`）：`h264`/`hevc` 这些编码名不区分位深，
 *    而系统硬解 10-bit（High 10 / Main 10）会**花屏**（部分区域马赛克）。设备实测：
 *    某 H.264 High 10（yuv420p10le / 1920x1080 / Level 5.1）条目被直连后，硬解花屏、
 *    约 30 秒后报错才回退转码；下发位深约束后服务端直接转码成 8-bit，画面正常。
 */
ClientPlaybackCapabilities DefaultClientPlaybackCapabilities();

/**
 * 构造 `DeviceProfile` JSON（放进 PlaybackInfo 请求体）。
 *
 * 字段遵循 Jellyfin 10.8 的 `DeviceProfile` 模型：DirectPlayProfiles / TranscodingProfiles /
 * CodecProfiles / SubtitleProfiles / MaxStreamingBitrate。
 */
nlohmann::json BuildDeviceProfile(const ClientPlaybackCapabilities &caps);

/**
 * 该 PlaybackInfo 响应里是否存在**可用**的播放地址
 * （TranscodingUrl / DirectStreamUrl / 可由 ItemId+MediaSourceId 拼出的静态流）。
 *
 * 用途：带上 DeviceProfile 后，若服务端既不能转码又认为不能直接播放，就会出现
 * "MediaSources 里没有任何可用 URL"的响应 —— 这时应当**去掉 DeviceProfile 重试一次**，
 * 退回"直连 + 本机软解"这条保底路径，而不是把用户丢在错误页。
 */
bool playbackInfoHasPlayableUrl(const nlohmann::json &playbackInfo);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_DEVICE_PROFILE_H */
