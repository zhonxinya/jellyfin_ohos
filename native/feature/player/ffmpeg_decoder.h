#ifndef JELLYFIN_PLAYER_FFMPEG_DECODER_H
#define JELLYFIN_PLAYER_FFMPEG_DECODER_H

#include <cstdint>
#include <string>
#include <vector>

namespace jellyfin {
namespace player {

/**
 * FFmpeg 软解码器。
 *
 * 构建期由 CMake 检测：找到 FFmpeg（`scripts/build_ffmpeg_ohos.sh` 的产物）时定义
 * `JELLYFIN_HAS_FFMPEG` 并链接 libavformat/libavcodec/libavutil/libswscale/libswresample；
 * 否则本类退化为"不可用"（open 返回 false）且**不会假装解码可用**。
 *
 * 取流方式：交叉编译时已 `--disable-network`（不用 FFmpeg 自带的 http/tls），
 * 由本工程 `core` 的 HTTP 客户端（含 mbedTLS，支持 https 与 Jellyfin 鉴权）取到字节后交给
 * FFmpeg 解析，避免引入第二套 TLS 实现。
 */
class FfmpegDecoder {
public:
    /** 软解探测结果：媒体信息 + 解码统计 */
    struct ProbeResult {
        bool ok = false;
        /** 失败原因（ok=false 时非空） */
        std::string error;
        std::string backend;     // "ffmpeg" / ""
        std::string container;   // 容器短名，如 matroska / mov
        std::string videoCodec;  // 如 hevc / h264
        std::string audioCodec;
        int width = 0;
        int height = 0;
        /** 解码器输出的像素格式（如 yuv420p10le） */
        std::string pixelFormat;
        double durationSec = 0.0;
        int64_t bitRate = 0;
        /** 成功解码的视频帧数 */
        int decodedFrames = 0;
        /** 首帧 PNG 落盘路径（调用方指定 outPngPath 且导出成功时非空） */
        std::string framePngPath;
    };

    /** 当前构建是否链接了 FFmpeg */
    static bool available();

    bool open(const std::string &url, const std::string &videoCodec = {});
    void close();
    bool isOpen() const { return open_; }
    const std::string &backendName() const { return backend_; }
    const std::string &url() const { return url_; }

    /**
     * 从内存缓冲软解：解析容器 → 打开软件视频解码器 → 解出前若干帧（可导出首帧 PNG）。
     *
     * @param data        媒体字节（调用方经 HTTP 取流；探测场景取文件前若干 MB 即可）
     * @param outPngPath  首帧 PNG 输出路径；为空则不落盘
     * @param maxFrames   最多解码帧数（默认 1，用于验证解码链路）
     * @param result      输出：媒体信息、解码统计、失败原因
     */
    static bool probeFromMemory(const std::vector<uint8_t> &data, const std::string &outPngPath,
                                ProbeResult &result, int maxFrames = 1);

private:
    bool open_ = false;
    std::string backend_;
    std::string url_;
};

} // namespace player
} // namespace jellyfin

#endif /* JELLYFIN_PLAYER_FFMPEG_DECODER_H */
