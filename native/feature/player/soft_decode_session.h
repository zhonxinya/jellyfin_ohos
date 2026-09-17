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
     * 跳转到指定时间点（秒）。
     * 用于续播（"继续观看"）：打开会话后 seek 到上次观看位置。
     * 实现：av_seek_frame(AVSEEK_FLAG_BACKWARD) + avcodec_flush_buffers。
     * @param seconds 目标时间点（秒）
     * @param error 输出错误信息
     * @return true 表示 seek 成功
     */
    bool seek(double seconds, std::string &error);

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
