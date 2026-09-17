#ifndef JELLYFIN_PLAYER_SOFT_DECODE_SESSION_H
#define JELLYFIN_PLAYER_SOFT_DECODE_SESSION_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace jellyfin {
namespace player {

/**
 * 流式软件解码会话（FFmpeg）。
 *
 * 与 `FfmpegDecoder::probeFromMemory()`（一次性内存探测）不同，本类面向**播放**：
 *  - 取流采用 **HTTP Range 分页**（复用 core 的 HttpClient，支持 https 与 Jellyfin 鉴权），
 *    通过自定义 AVIOContext 交给 libavformat，做到"边下边解"而不是先整片下载；
 *  - `nextFrameRgba()` 逐帧输出 RGBA（可指定最大宽度自动缩放），供上层渲染；
 *  - 支持 seek（AVIO seek 回调 → 重新定位到目标字节）。
 *
 * 线程约束: 同一会话需在**单线程**内顺序调用（解码器与 AVIO 均非线程安全）；
 * 渲染/驱动由上层（NAPI→ArkTS 定时器）负责。
 */
class SoftDecodeSession {
public:
    struct FrameInfo {
        bool ok = false;
        /** 失败/结束原因（ok=false 时非空；播放结束为 "eof"） */
        std::string error;
        int width = 0;
        int height = 0;
        /** 该帧在媒体中的时间戳（秒），用于帧节奏控制 */
        double ptsSec = 0.0;
        /** 已输出帧序号（从 1 开始） */
        int64_t frameIndex = 0;
        /** 本次调用是否顺带执行了一次排队的 seek */
        bool seekApplied = false;
        /** 若执行了 seek，这里是从此帧开始的解码位置（秒） */
        double seekedToSec = 0.0;
        /** seek 失败原因（seekApplied=false 且非空时表示失败） */
        std::string seekError;
    };

    SoftDecodeSession();
    ~SoftDecodeSession();

    SoftDecodeSession(const SoftDecodeSession &) = delete;
    SoftDecodeSession &operator=(const SoftDecodeSession &) = delete;

    /** 当前构建是否具备软解能力（链接了 FFmpeg） */
    static bool available();

    /**
     * 打开流并探测媒体信息（会执行 Range 分页取流 + 打开软件解码器）。
     * @param url 允许 http/https；鉴权参数应已包含在 URL 中（Jellyfin 直连地址自带 api_key）
     */
    bool openUrl(const std::string &url, std::string &error);

    /**
     * 解出下一帧并转换为 RGBA（`maxWidth>0` 时等比缩放到不超过该宽度）。
     * 输出 `rgba` 尺寸为 w*h*4；播放到结尾时返回 false 且 info.error == "eof"。
     */
    bool nextFrameRgba(int maxWidth, std::vector<uint8_t> &rgba, FrameInfo &info);

    /**
     * 跳转到指定时间点（秒）—— **立即执行**，仅适用于没有解码在飞的时候（如刚 open 完）。
     * 播放中请用 `requestSeek()`：本方法会经自定义 AVIO 回调做同步 HTTP 取流。
     */
    bool seek(double seconds, std::string &error);

    /**
     * 请求跳转（线程安全、非阻塞）：只记录目标位置，真正的 `av_seek_frame` 由下一次
     * `nextFrameRgba()` 在**解码线程**上执行。
     *
     * 为什么必须排队而不是直接 seek：
     *  1. `seek()` 里的 `av_seek_frame` 会经 AVIO 回调走同步 HTTP Range 取流，
     *     在 ArkTS 侧（UI 线程）调用就是"UI 线程做网络 I/O"——本工程已实测会触发 appfreeze；
     *  2. 播放中解码线程可能正在 `av_read_frame`，与 UI 线程的 `av_seek_frame` 并发操作
     *     同一个 AVFormatContext 属于数据竞争（表现为 seek 不生效或读到错乱数据）。
     * 排队后：seek 与解码在同一条线程上串行，UI 侧调用立即返回。
     */
    void requestSeek(double seconds);

    void close();

    bool isOpen() const;
    const std::string &videoCodec() const;
    const std::string &container() const;
    int width() const;
    int height() const;
    double durationSec() const;
    /** 已通过 Range 取到的字节数（诊断用） */
    int64_t bytesFetched() const;
    /** 已解出的视频帧数 */
    int64_t framesDecoded() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_SOFT_DECODE_SESSION_H */
