#include "ffmpeg_decoder.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

#if defined(JELLYFIN_HAS_FFMPEG)
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}
#endif

namespace jellyfin {
namespace player {

#if defined(JELLYFIN_HAS_FFMPEG)
namespace {

/** FFmpeg 错误码 → 可读字符串 */
std::string AvError(int code)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}

/** 内存读流：由上层 HTTP 客户端取到字节后交给 libavformat（本构建未启用网络协议） */
struct MemIO {
    const uint8_t *data = nullptr;
    size_t size = 0;
    size_t pos = 0;
};

int MemRead(void *opaque, uint8_t *buf, int bufSize)
{
    MemIO *io = static_cast<MemIO *>(opaque);
    if (io->pos >= io->size) {
        return AVERROR_EOF;
    }
    const size_t n = std::min(static_cast<size_t>(bufSize), io->size - io->pos);
    std::memcpy(buf, io->data + io->pos, n);
    io->pos += n;
    return static_cast<int>(n);
}

int64_t MemSeek(void *opaque, int64_t offset, int whence)
{
    MemIO *io = static_cast<MemIO *>(opaque);
    if (whence == AVSEEK_SIZE) {
        return static_cast<int64_t>(io->size);
    }
    int64_t base = 0;
    if (whence == SEEK_CUR) {
        base = static_cast<int64_t>(io->pos);
    } else if (whence == SEEK_END) {
        base = static_cast<int64_t>(io->size);
    } else if (whence != SEEK_SET) {
        return AVERROR(EINVAL);
    }
    const int64_t target = base + offset;
    if (target < 0) {
        return AVERROR(EINVAL);
    }
    io->pos = static_cast<size_t>(std::min<int64_t>(target, static_cast<int64_t>(io->size)));
    return target;
}

/** 把解码出的帧转成 PNG 写盘（PNG 单包自包含，无需 muxer） */
bool WriteFrameAsPng(const AVFrame *src, const std::string &path, int maxWidth, std::string &error)
{
    const int srcW = src->width;
    const int srcH = src->height;
    if (srcW <= 0 || srcH <= 0) {
        error = "解码帧尺寸无效";
        return false;
    }
    const double scale = (maxWidth > 0 && srcW > maxWidth) ? (static_cast<double>(maxWidth) / srcW) : 1.0;
    const int dstW = std::max(2, static_cast<int>(srcW * scale));
    const int dstH = std::max(2, static_cast<int>(srcH * scale));

    SwsContext *sws = sws_getContext(srcW, srcH, static_cast<AVPixelFormat>(src->format),
                                     dstW, dstH, AV_PIX_FMT_RGB24, SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (sws == nullptr) {
        error = "创建缩放上下文失败";
        return false;
    }

    AVFrame *rgb = av_frame_alloc();
    rgb->format = AV_PIX_FMT_RGB24;
    rgb->width = dstW;
    rgb->height = dstH;
    if (av_frame_get_buffer(rgb, 32) < 0) {
        sws_freeContext(sws);
        av_frame_free(&rgb);
        error = "分配 RGB 帧缓冲失败";
        return false;
    }
    sws_scale(sws, src->data, src->linesize, 0, srcH, rgb->data, rgb->linesize);
    sws_freeContext(sws);

    const AVCodec *pngCodec = avcodec_find_encoder(AV_CODEC_ID_PNG);
    if (pngCodec == nullptr) {
        av_frame_free(&rgb);
        error = "本构建未包含 PNG 编码器（需要 --enable-encoder=png）";
        return false;
    }
    AVCodecContext *enc = avcodec_alloc_context3(pngCodec);
    enc->width = dstW;
    enc->height = dstH;
    enc->pix_fmt = AV_PIX_FMT_RGB24;
    enc->time_base = AVRational{1, 25};
    bool ok = false;
    if (avcodec_open2(enc, pngCodec, nullptr) < 0) {
        error = "打开 PNG 编码器失败";
    } else if (avcodec_send_frame(enc, rgb) < 0) {
        error = "PNG 编码提交帧失败";
    } else {
        AVPacket *pkt = av_packet_alloc();
        const int rc = avcodec_receive_packet(enc, pkt);
        if (rc < 0) {
            error = "PNG 编码取包失败：" + AvError(rc);
        } else {
            FILE *fp = std::fopen(path.c_str(), "wb");
            if (fp == nullptr) {
                error = "无法写入 PNG 文件：" + path;
            } else {
                ok = std::fwrite(pkt->data, 1, static_cast<size_t>(pkt->size), fp) ==
                     static_cast<size_t>(pkt->size);
                std::fclose(fp);
                if (!ok) {
                    error = "PNG 写盘不完整";
                }
            }
        }
        av_packet_free(&pkt);
    }

    avcodec_free_context(&enc);
    av_frame_free(&rgb);
    return ok;
}

} // namespace
#endif /* JELLYFIN_HAS_FFMPEG */

bool FfmpegDecoder::available()
{
#if defined(JELLYFIN_HAS_FFMPEG)
    return true;
#else
    return false;
#endif
}

bool FfmpegDecoder::open(const std::string &url, const std::string & /*videoCodec*/)
{
    if (url.empty()) {
        return false;
    }
    url_ = url;
#if defined(JELLYFIN_HAS_FFMPEG)
    // 本类只直接打开本地路径：网络取流（含 https / Jellyfin 鉴权）由 core 的 HTTP 客户端负责，
    // 取到字节后用 probeFromMemory() 解析，避免引入第二套 TLS 实现。
    const bool localFile = url.rfind("file:", 0) == 0 || url[0] == '/';
    if (localFile) {
        backend_ = "ffmpeg";
        open_ = true;
        return true;
    }
    backend_.clear();
    open_ = false;
    return false;
#else
    // 未链接 FFmpeg：明确报告不可用，不假装解码可用
    backend_.clear();
    open_ = false;
    return false;
#endif
}

void FfmpegDecoder::close()
{
    open_ = false;
    backend_.clear();
    url_.clear();
}

bool FfmpegDecoder::probeFromMemory(const std::vector<uint8_t> &data, const std::string &outPngPath,
                                    ProbeResult &result, int maxFrames)
{
    result = ProbeResult{};

#if !defined(JELLYFIN_HAS_FFMPEG)
    (void)data;
    (void)outPngPath;
    (void)maxFrames;
    result.error = "本构建未链接 FFmpeg（JELLYFIN_HAS_FFMPEG 未定义）";
    return false;
#else
    if (data.empty()) {
        result.error = "输入字节为空";
        return false;
    }
    result.backend = "ffmpeg";

    MemIO io;
    io.data = data.data();
    io.size = data.size();

    constexpr int kAvioBufSize = 64 * 1024;
    unsigned char *avioBuf = static_cast<unsigned char *>(av_malloc(kAvioBufSize));
    if (avioBuf == nullptr) {
        result.error = "分配 AVIO 缓冲失败";
        return false;
    }
    AVIOContext *avio = avio_alloc_context(avioBuf, kAvioBufSize, 0, &io, MemRead, nullptr, MemSeek);
    if (avio == nullptr) {
        av_free(avioBuf);
        result.error = "创建 AVIO 上下文失败";
        return false;
    }

    AVFormatContext *fmt = avformat_alloc_context();
    fmt->pb = avio;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

    int rc = avformat_open_input(&fmt, nullptr, nullptr, nullptr);
    if (rc < 0) {
        result.error = "解析容器失败：" + AvError(rc);
        avformat_close_input(&fmt);
        avio_context_free(&avio);
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        result.error = "读取流信息失败（数据不足或文件损坏）";
        avformat_close_input(&fmt);
        avio_context_free(&avio);
        return false;
    }

    if (fmt->iformat != nullptr && fmt->iformat->name != nullptr) {
        result.container = fmt->iformat->name;
    }
    if (fmt->duration > 0) {
        result.durationSec = static_cast<double>(fmt->duration) / AV_TIME_BASE;
    }
    if (fmt->bit_rate > 0) {
        result.bitRate = fmt->bit_rate;
    }

    const int videoIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    const int audioIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audioIndex >= 0) {
        AVCodecParameters *apar = fmt->streams[audioIndex]->codecpar;
        const AVCodecDescriptor *adesc = avcodec_descriptor_get(apar->codec_id);
        if (adesc != nullptr && adesc->name != nullptr) {
            result.audioCodec = adesc->name;
        }
    }
    if (videoIndex < 0) {
        result.error = "未找到视频流";
        avformat_close_input(&fmt);
        avio_context_free(&avio);
        return false;
    }

    AVStream *vstream = fmt->streams[videoIndex];
    AVCodecParameters *par = vstream->codecpar;
    const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);
    if (desc != nullptr && desc->name != nullptr) {
        result.videoCodec = desc->name;
    }
    result.width = par->width;
    result.height = par->height;

    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (codec == nullptr) {
        result.error = "本构建不含该视频解码器：" + result.videoCodec;
        avformat_close_input(&fmt);
        avio_context_free(&avio);
        return false;
    }
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    if (avcodec_parameters_to_context(dec, par) < 0 || avcodec_open2(dec, codec, nullptr) < 0) {
        result.error = "打开视频解码器失败：" + result.videoCodec;
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        avio_context_free(&avio);
        return false;
    }
    if (dec->pix_fmt != AV_PIX_FMT_NONE) {
        const char *pfName = av_get_pix_fmt_name(dec->pix_fmt);
        if (pfName != nullptr) {
            result.pixelFormat = pfName;
        }
    }

    // 逐包解码，直到拿满 maxFrames 帧（探测场景数据可能只取了文件前若干 MB，包用尽即停止）
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    bool gotFrame = false;
    bool exportedPng = false;
    std::string pngError;

    while (result.decodedFrames < maxFrames && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != videoIndex) {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(dec, pkt) < 0) {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);
        while (result.decodedFrames < maxFrames && avcodec_receive_frame(dec, frame) == 0) {
            result.decodedFrames++;
            if (!gotFrame) {
                gotFrame = true;
                result.width = frame->width > 0 ? frame->width : result.width;
                result.height = frame->height > 0 ? frame->height : result.height;
                if (!outPngPath.empty()) {
                    exportedPng = WriteFrameAsPng(frame, outPngPath, 640, pngError);
                    if (exportedPng) {
                        result.framePngPath = outPngPath;
                    }
                }
            }
            av_frame_unref(frame);
        }
    }

    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    avio_context_free(&avio);

    if (result.decodedFrames <= 0) {
        result.error = "未能解出任何视频帧（可能取到的字节不足）";
        return false;
    }
    if (!outPngPath.empty() && !exportedPng) {
        // 解码成功但首帧导出失败：如实报告（不把探测判为成功导出）
        result.error = pngError.empty() ? "首帧导出失败" : pngError;
        result.ok = true;  // 解码本身成功
        return true;
    }
    result.ok = true;
    return true;
#endif
}

} // namespace player
} // namespace jellyfin
