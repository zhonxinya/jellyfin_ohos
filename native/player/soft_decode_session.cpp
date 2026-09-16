#include "soft_decode_session.h"

#include "http_client.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <sstream>

#if defined(JELLYFIN_HAS_FFMPEG)
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
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

std::string AvErrorStr(int code)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}

/** 从 Content-Range: bytes 0-0/12345 解析总长度 */
int64_t ParseTotalFromContentRange(const std::string &value)
{
    const size_t slash = value.rfind('/');
    if (slash == std::string::npos) {
        return -1;
    }
    const std::string tail = value.substr(slash + 1);
    if (tail.empty() || tail == "*") {
        return -1;
    }
    try {
        return std::stoll(tail);
    } catch (...) {
        return -1;
    }
}

/**
 * HTTP Range 分页读流：把"读字节"翻译成按需 Range 请求，并缓存最近一块。
 * chunk 默认 1 MiB —— 过多小请求会拖慢解码，过大则增加等待。
 */
class HttpRangeReader {
public:
    HttpRangeReader(std::string url, size_t chunkBytes = 1024 * 1024)
        : url_(std::move(url)), chunk_(chunkBytes)
    {
        http_.setReadTimeoutSec(30);
        http_.setConnectTimeoutSec(10);
    }

    /**
     * 预取首个分片并尽力推断总长度：
     *  - 服务器返回 206（支持 Range）→ 总长度未知，按需继续 Range 读取，读到空响应即 EOF
     *  - 服务器忽略 Range 返回 200（整片）→ 总长度 = body 大小
     * 首个分片会直接放进缓存，避免紧接着的 read 重复请求同一块。
     */
    int64_t probeSize()
    {
        HttpHeaders headers;
        headers["Range"] = "bytes=0-" + std::to_string(chunk_ - 1);
        const HttpResponse resp = http_.get(url_, headers);
        if (resp.status >= 400 || resp.body.empty()) {
            const HttpResponse plain = http_.get(url_, {});
            if (plain.status >= 400 || plain.body.empty()) {
                return 0;
            }
            bytesFetched_ += static_cast<int64_t>(plain.body.size());
            cache_.assign(plain.body.begin(), plain.body.end());
            cacheStart_ = 0;
            size_ = static_cast<int64_t>(cache_.size());
            return size_;
        }
        bytesFetched_ += static_cast<int64_t>(resp.body.size());
        cache_.assign(resp.body.begin(), resp.body.end());
        cacheStart_ = 0;
        if (resp.status == 200) {
            // 服务器忽略了 Range：这就是整片内容
            size_ = static_cast<int64_t>(cache_.size());
        }
        return size_;
    }

    int64_t size() const { return size_; }
    int64_t bytesFetched() const { return bytesFetched_; }

    /** 读取最多 bufSize 字节到 buf；返回实际字节数，0 表示 EOF，-1 表示错误 */
    int read(uint8_t *buf, int bufSize, std::string &error)
    {
        if (bufSize <= 0) {
            return 0;
        }
        if (size_ >= 0 && pos_ >= size_) {
            return 0;
        }
        if (!inCache(pos_)) {
            if (!fillCache(pos_, error)) {
                return -1;
            }
        }
        const int64_t cacheEnd = cacheStart_ + static_cast<int64_t>(cache_.size());
        const int64_t avail = cacheEnd - pos_;
        if (avail <= 0) {
            return 0;
        }
        const int n = static_cast<int>(std::min<int64_t>(bufSize, avail));
        std::memcpy(buf, cache_.data() + static_cast<size_t>(pos_ - cacheStart_), static_cast<size_t>(n));
        pos_ += n;
        return n;
    }

    /** 定位（不预取；下次 read 时按需拉取） */
    int64_t seek(int64_t offset)
    {
        if (offset < 0) {
            return -1;
        }
        if (size_ >= 0) {
            offset = std::min(offset, size_);
        }
        pos_ = offset;
        return pos_;
    }

private:
    bool inCache(int64_t pos) const
    {
        return !cache_.empty() && pos >= cacheStart_ &&
               pos < cacheStart_ + static_cast<int64_t>(cache_.size());
    }

    bool fillCache(int64_t pos, std::string &error)
    {
        if (size_ >= 0 && pos >= size_) {
            return false;
        }
        const int64_t end = (size_ >= 0) ? std::min<int64_t>(pos + static_cast<int64_t>(chunk_) - 1, size_ - 1)
                                         : pos + static_cast<int64_t>(chunk_) - 1;
        HttpHeaders headers;
        headers["Range"] = "bytes=" + std::to_string(pos) + "-" + std::to_string(end);
        const HttpResponse resp = http_.get(url_, headers);
        if (resp.status >= 400 || resp.body.empty()) {
            // 服务器可能不支持 Range：退回普通 GET（仅首次可用）
            if (pos == 0) {
                const HttpResponse plain = http_.get(url_, {});
                if (plain.status >= 400 || plain.body.empty()) {
                    error = plain.error.empty()
                                ? ("取流失败：HTTP " + std::to_string(plain.status))
                                : ("取流失败：" + plain.error);
                    return false;
                }
                bytesFetched_ += static_cast<int64_t>(plain.body.size());
                cache_.assign(plain.body.begin(), plain.body.end());
                cacheStart_ = 0;
                if (size_ < 0) {
                    size_ = static_cast<int64_t>(cache_.size());
                }
                return true;
            }
            error = resp.error.empty() ? ("取流失败：HTTP " + std::to_string(resp.status))
                                       : ("取流失败：" + resp.error);
            return false;
        }
        bytesFetched_ += static_cast<int64_t>(resp.body.size());
        cache_.assign(resp.body.begin(), resp.body.end());
        cacheStart_ = pos;
        if (size_ < 0 && resp.status == 200) {
            // 服务器忽略了 Range，返回整片
            size_ = static_cast<int64_t>(cache_.size());
        }
        return true;
    }

    std::string url_;
    size_t chunk_;
    HttpClient http_;
    std::string cache_;
    int64_t cacheStart_ = 0;
    int64_t pos_ = 0;
    int64_t size_ = -1;
    int64_t bytesFetched_ = 0;
};

struct AvioBridge {
    HttpRangeReader *reader = nullptr;
    std::string error;
};

int BridgeRead(void *opaque, uint8_t *buf, int bufSize)
{
    AvioBridge *bridge = static_cast<AvioBridge *>(opaque);
    const int n = bridge->reader->read(buf, bufSize, bridge->error);
    if (n < 0) {
        return AVERROR(EIO);
    }
    return n;
}

int64_t BridgeSeek(void *opaque, int64_t offset, int whence)
{
    AvioBridge *bridge = static_cast<AvioBridge *>(opaque);
    if (whence == AVSEEK_SIZE) {
        return bridge->reader->size();
    }
    int64_t base = 0;
    if (whence == SEEK_CUR) {
        // libavformat 会传入 SEEK_CUR；这里没有暴露当前位置，交由下面统一处理
        base = -1;
    } else if (whence == SEEK_END) {
        const int64_t size = bridge->reader->size();
        if (size < 0) {
            return AVERROR(EINVAL);
        }
        base = size;
    } else if (whence != SEEK_SET) {
        return AVERROR(EINVAL);
    }
    if (base < 0) {
        // SEEK_CUR 不支持（libavformat 对可 seek 流一般用 SEEK_SET；必要时退回顺序读）
        return AVERROR(ENOSYS);
    }
    return bridge->reader->seek(base + offset);
}

} // namespace
#endif /* JELLYFIN_HAS_FFMPEG */

struct SoftDecodeSession::Impl {
#if defined(JELLYFIN_HAS_FFMPEG)
    std::unique_ptr<HttpRangeReader> reader;
    AvioBridge bridge;
    AVIOContext *avio = nullptr;
    AVFormatContext *fmt = nullptr;
    AVCodecContext *dec = nullptr;
    AVPacket *pkt = nullptr;
    AVFrame *frame = nullptr;
    SwsContext *sws = nullptr;
    int videoIndex = -1;
    int swsSrcW = 0;
    int swsSrcH = 0;
    int swsSrcFmt = -1;
    int swsDstW = 0;
    int swsDstH = 0;
    bool eof = false;
    bool failed = false;
    std::string error;
#endif
    std::string url;
    std::string codec;
    std::string container;
    int width = 0;
    int height = 0;
    double duration = 0.0;
    int64_t frames = 0;
    bool open = false;
};

SoftDecodeSession::SoftDecodeSession() : impl_(new Impl()) {}

SoftDecodeSession::~SoftDecodeSession()
{
    close();
}

bool SoftDecodeSession::available()
{
#if defined(JELLYFIN_HAS_FFMPEG)
    return true;
#else
    return false;
#endif
}

bool SoftDecodeSession::openUrl(const std::string &url, std::string &error)
{
    close();
    impl_->url = url;

#if !defined(JELLYFIN_HAS_FFMPEG)
    (void)url;
    error = "本构建未链接 FFmpeg（JELLYFIN_HAS_FFMPEG 未定义）";
    return false;
#else
    if (url.empty()) {
        error = "URL 为空";
        return false;
    }
    impl_->reader.reset(new HttpRangeReader(url));
    const int64_t size = impl_->reader->probeSize();
    if (size == 0) {
        error = "取流失败：服务器返回空内容";
        impl_->reader.reset();
        return false;
    }
    impl_->bridge.reader = impl_->reader.get();

    constexpr int kAvioBuf = 64 * 1024;
    unsigned char *avioBuf = static_cast<unsigned char *>(av_malloc(kAvioBuf));
    impl_->avio = avio_alloc_context(avioBuf, kAvioBuf, 0, &impl_->bridge, BridgeRead, nullptr, BridgeSeek);
    if (impl_->avio == nullptr) {
        av_free(avioBuf);
        error = "创建 AVIO 上下文失败";
        return false;
    }
    impl_->fmt = avformat_alloc_context();
    impl_->fmt->pb = impl_->avio;
    impl_->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

    int rc = avformat_open_input(&impl_->fmt, nullptr, nullptr, nullptr);
    if (rc < 0) {
        error = "解析容器失败：" + AvErrorStr(rc);
        close();
        return false;
    }
    if (avformat_find_stream_info(impl_->fmt, nullptr) < 0) {
        error = "读取流信息失败" + (impl_->bridge.error.empty() ? std::string() : ("：" + impl_->bridge.error));
        close();
        return false;
    }
    if (impl_->fmt->iformat != nullptr && impl_->fmt->iformat->name != nullptr) {
        impl_->container = impl_->fmt->iformat->name;
    }
    if (impl_->fmt->duration > 0) {
        impl_->duration = static_cast<double>(impl_->fmt->duration) / AV_TIME_BASE;
    }

    impl_->videoIndex = av_find_best_stream(impl_->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (impl_->videoIndex < 0) {
        error = "未找到视频流";
        close();
        return false;
    }
    AVCodecParameters *par = impl_->fmt->streams[impl_->videoIndex]->codecpar;
    const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);
    if (desc != nullptr && desc->name != nullptr) {
        impl_->codec = desc->name;
    }
    impl_->width = par->width;
    impl_->height = par->height;

    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (codec == nullptr) {
        error = "本构建不含该视频解码器：" + impl_->codec;
        close();
        return false;
    }
    impl_->dec = avcodec_alloc_context3(codec);
    if (impl_->dec == nullptr || avcodec_parameters_to_context(impl_->dec, par) < 0 ||
        avcodec_open2(impl_->dec, codec, nullptr) < 0) {
        error = "打开视频解码器失败：" + impl_->codec;
        close();
        return false;
    }
    impl_->pkt = av_packet_alloc();
    impl_->frame = av_frame_alloc();
    if (impl_->pkt == nullptr || impl_->frame == nullptr) {
        error = "分配解码缓冲失败";
        close();
        return false;
    }
    impl_->open = true;
    return true;
#endif
}

bool SoftDecodeSession::nextFrameRgba(int maxWidth, std::vector<uint8_t> &rgba, FrameInfo &info)
{
    info = FrameInfo{};
#if !defined(JELLYFIN_HAS_FFMPEG)
    info.error = "本构建未链接 FFmpeg";
    return false;
#else
    if (!impl_->open || impl_->failed || impl_->eof) {
        info.error = impl_->error.empty() ? "会话未打开" : impl_->error;
        return false;
    }

    for (;;) {
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        if (rc == 0) {
            break;  // 有帧可用
        }
        if (rc == AVERROR(EAGAIN)) {
            // 需要更多包
            int readRc = 0;
            for (;;) {
                readRc = av_read_frame(impl_->fmt, impl_->pkt);
                if (readRc < 0) {
                    break;
                }
                if (impl_->pkt->stream_index == impl_->videoIndex) {
                    break;
                }
                av_packet_unref(impl_->pkt);
            }
            if (readRc < 0) {
                // 数据用完：冲刷解码器
                avcodec_send_packet(impl_->dec, nullptr);
                const int flushRc = avcodec_receive_frame(impl_->dec, impl_->frame);
                if (flushRc == 0) {
                    break;
                }
                impl_->eof = true;
                if (!impl_->bridge.error.empty()) {
                    impl_->failed = true;
                    impl_->error = impl_->bridge.error;
                    info.error = impl_->error;
                    return false;
                }
                info.error = "eof";
                return false;
            }
            if (avcodec_send_packet(impl_->dec, impl_->pkt) < 0) {
                av_packet_unref(impl_->pkt);
                continue;
            }
            av_packet_unref(impl_->pkt);
            continue;
        }
        if (rc == AVERROR_EOF) {
            impl_->eof = true;
            info.error = "eof";
            return false;
        }
        impl_->failed = true;
        impl_->error = "解码失败：" + AvErrorStr(rc);
        info.error = impl_->error;
        return false;
    }

    AVFrame *frame = impl_->frame;
    const int srcW = frame->width > 0 ? frame->width : impl_->width;
    const int srcH = frame->height > 0 ? frame->height : impl_->height;
    const double scale = (maxWidth > 0 && srcW > maxWidth) ? (static_cast<double>(maxWidth) / srcW) : 1.0;
    const int dstW = std::max(2, static_cast<int>(srcW * scale));
    const int dstH = std::max(2, static_cast<int>(srcH * scale));

    if (impl_->sws == nullptr || impl_->swsSrcW != srcW || impl_->swsSrcH != srcH ||
        impl_->swsSrcFmt != frame->format || impl_->swsDstW != dstW || impl_->swsDstH != dstH) {
        if (impl_->sws != nullptr) {
            sws_freeContext(impl_->sws);
        }
        impl_->sws = sws_getContext(srcW, srcH, static_cast<AVPixelFormat>(frame->format), dstW, dstH,
                                    AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        impl_->swsSrcW = srcW;
        impl_->swsSrcH = srcH;
        impl_->swsSrcFmt = frame->format;
        impl_->swsDstW = dstW;
        impl_->swsDstH = dstH;
        if (impl_->sws == nullptr) {
            impl_->failed = true;
            impl_->error = "创建缩放上下文失败";
            info.error = impl_->error;
            av_frame_unref(frame);
            return false;
        }
    }

    rgba.assign(static_cast<size_t>(dstW) * dstH * 4u, 0);
    uint8_t *dstData[4] = {rgba.data(), nullptr, nullptr, nullptr};
    int dstLinesize[4] = {dstW * 4, 0, 0, 0};
    sws_scale(impl_->sws, frame->data, frame->linesize, 0, srcH, dstData, dstLinesize);

    int64_t pts = frame->pts;
    const AVRational tb = impl_->fmt->streams[impl_->videoIndex]->time_base;
    if (pts == AV_NOPTS_VALUE && frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        pts = frame->best_effort_timestamp;
    }
    info.ptsSec = (pts == AV_NOPTS_VALUE || tb.den == 0) ? 0.0 : (static_cast<double>(pts) * tb.num / tb.den);
    info.width = dstW;
    info.height = dstH;
    info.ok = true;
    impl_->frames++;
    info.frameIndex = impl_->frames;
    av_frame_unref(frame);
    return true;
#endif
}

void SoftDecodeSession::close()
{
#if defined(JELLYFIN_HAS_FFMPEG)
    if (impl_->sws != nullptr) {
        sws_freeContext(impl_->sws);
        impl_->sws = nullptr;
    }
    if (impl_->frame != nullptr) {
        av_frame_free(&impl_->frame);
    }
    if (impl_->pkt != nullptr) {
        av_packet_free(&impl_->pkt);
    }
    if (impl_->dec != nullptr) {
        avcodec_free_context(&impl_->dec);
    }
    if (impl_->fmt != nullptr) {
        avformat_close_input(&impl_->fmt);
    }
    if (impl_->avio != nullptr) {
        avio_context_free(&impl_->avio);
    }
    impl_->reader.reset();
    impl_->videoIndex = -1;
    impl_->swsSrcW = 0;
    impl_->swsSrcH = 0;
    impl_->swsSrcFmt = -1;
    impl_->eof = false;
    impl_->failed = false;
    impl_->error.clear();
#endif
    impl_->open = false;
    impl_->frames = 0;
    impl_->codec.clear();
    impl_->container.clear();
    impl_->width = 0;
    impl_->height = 0;
    impl_->duration = 0.0;
}

bool SoftDecodeSession::isOpen() const
{
    return impl_->open;
}

const std::string &SoftDecodeSession::videoCodec() const
{
    return impl_->codec;
}

const std::string &SoftDecodeSession::container() const
{
    return impl_->container;
}

int SoftDecodeSession::width() const
{
    return impl_->width;
}

int SoftDecodeSession::height() const
{
    return impl_->height;
}

double SoftDecodeSession::durationSec() const
{
    return impl_->duration;
}

int64_t SoftDecodeSession::bytesFetched() const
{
#if defined(JELLYFIN_HAS_FFMPEG)
    return impl_->reader ? impl_->reader->bytesFetched() : 0;
#else
    return 0;
#endif
}

int64_t SoftDecodeSession::framesDecoded() const
{
    return impl_->frames;
}

} // namespace player
} // namespace jellyfin
