#include "soft_decode_session.h"

#include "player_log.h"
#include "range_cache.h"
#include "range_fetcher.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
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

int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

std::string AvErrorStr(int code)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}

/**
 * 一帧都没解出来时，连续被拒多少包就判定"解码器不可用"。
 * 取 30：正常码流的开头（sequence header + 关键帧）远小于这个数，
 * 而"每包必拒"的坏情况（AV1 + 自带解码器）会立刻命中，不必把整片读完。
 */
constexpr int kMaxSendRejects = 30;

struct AvioBridge {
    RangeCache *reader = nullptr;
    std::string error;
};

int BridgeRead(void *opaque, uint8_t *buf, int bufSize)
{
    auto *bridge = static_cast<AvioBridge *>(opaque);
    const int n = bridge->reader->read(buf, bufSize, bridge->error);
    if (n < 0) {
        return AVERROR(EIO);
    }
    return n;
}

int64_t BridgeSeek(void *opaque, int64_t offset, int whence)
{
    auto *bridge = static_cast<AvioBridge *>(opaque);
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

/**
 * 选择视频解码器：AV1 **必须**优先用 libdav1d。
 *
 * 为什么（本工程实测的根因，别再退回自带 av1 解码器）：
 * FFmpeg 7.1 的 `libavcodec/av1dec.c` 在 `get_pixel_format()` 末尾有一段硬判断 ——
 * `ff_get_format()` 之后若 `avctx->hwaccel == NULL`（即没有真的初始化出硬件加速），
 * 直接 `av_log("Your platform doesn't support hardware accelerated AV1 decoding")`
 * 并 `return AVERROR(ENOSYS)`。而"纯软解"的绕过分支是那段
 * `for (int i = 0; pix_fmts[i] != pix_fmt; i++) if (pix_fmts[i] == avctx->pix_fmt)` ——
 * 它只遍历**硬件格式**，本工程的 FFmpeg 是 `--disable-hwaccels` 构建的
 * （`HWACCEL_MAX == 0`，候选列表里只剩软件格式），这个分支永远进不去。
 * 后果：自带 av1 解码器**每一包都返回 -38（Function not implemented）**，一帧都解不出来；
 * 而 `SoftDecodeSession` 只把该值当作"这包没被接受"继续读，最终读到文件末尾当作 `eof` ——
 * 设备上表现为"回退软解后进度条不动、画面纯黑、没有任何错误提示"。
 * 该结论已用同源码/同 configure 的宿主二进制复现（600 包 / 0 帧）。
 *
 * dav1d（BSD-2-Clause）是独立的多线程 AV1 解码器，也是服务端与桌面播放器实际在用的那个；
 * 交叉编译与部署见 `scripts/build_dav1d_ohos.sh`。
 */
struct DecoderChoice {
    const AVCodec *codec = nullptr;
    /** 选择理由（进日志，便于在设备上确认"到底谁在解"） */
    std::string note;
    /** 是否为 OpenHarmony AVCodec（ohcodec）解码器：打开时需要 allow_sw，见 openUrl */
    bool ohCodec = false;
};

/**
 * 选择视频解码器。优先级：
 *  ① **H.264 / HEVC → `h264_oh` / `hevc_oh`**（OpenHarmony AVCodec，设备侧硬解）
 *     —— FFmpeg 8.0 起上游提供（`--enable-ohcodec`，走 OH_AVCodec NDK）。
 *     本机实测：libavcodec 会 DT_NEEDED `libnative_media_vdec.so` 等三个系统库。
 *     设备上没有该编码的硬件编解码器时，ohdec 会按 `allow_sw=1` 退回**系统软件**编解码器
 *     （见 openUrl 的选项），因此模拟器/老设备也能走通，只是不算硬解。
 *  ② **AV1 → `libdav1d`**：FFmpeg 自带的 `av1` 解码器在没有硬件加速的构建里恒返回
 *     ENOSYS、一帧都解不出来（根因见下方长注释与 README），必须用 dav1d。
 *     （上游目前**没有** AV1 的 ohcodec 解码器：ohcodec.h 只映射 H.264/HEVC。）
 *  ③ 其余编码 → FFmpeg 自带解码器（如 vp9 / mpeg4 / wmv3）。
 */
DecoderChoice PickVideoDecoder(AVCodecID id)
{
    DecoderChoice choice;
    if (id == AV_CODEC_ID_H264 || id == AV_CODEC_ID_HEVC) {
        // ⚠ 名字容易记错（本工程实测踩过）：configure 里的**组件名**是 `h264_oh` / `hevc_oh`，
        // 但运行时 FFCodec 的 `.p.name` 是 `h264_ohcodec` / `hevc_ohcodec`
        // （见上游 libavcodec/ohdec.c 的 DECLARE_OHCODEC_VDEC 宏：`.p.name = #short_name "_ohcodec"`）。
        // `avcodec_find_decoder_by_name()` 匹配的是后者 —— 用组件名会返回 nullptr，
        // 于是"编译进了硬解却永远选不到"，且表面上一切正常（只是悄悄退回自带解码器）。
        const char *ohName = (id == AV_CODEC_ID_H264) ? "h264_ohcodec" : "hevc_ohcodec";
        const AVCodec *oh = avcodec_find_decoder_by_name(ohName);
        if (oh != nullptr) {
            choice.codec = oh;
            choice.ohCodec = true;
            choice.note = std::string(ohName) + "（OpenHarmony AVCodec，设备硬解）";
            return choice;
        }
        choice.note = "本构建没有 ohcodec 解码器（需 FFmpeg 8.0 + --enable-ohcodec）";
    }
    if (id == AV_CODEC_ID_AV1) {
        const AVCodec *dav1d = avcodec_find_decoder_by_name("libdav1d");
        if (dav1d != nullptr) {
            choice.codec = dav1d;
            choice.note += (choice.note.empty() ? "" : "；") + std::string("AV1 → libdav1d");
            return choice;
        }
        choice.note += (choice.note.empty() ? "" : "；") +
                       std::string("AV1 → 自带 av1 解码器（本构建没有 libdav1d，很可能解不出帧）");
    }
    const AVCodec *fallback = avcodec_find_decoder(id);
    if (fallback != nullptr) {
        if (choice.note.empty()) {
            choice.note = fallback->name;
        }
    }
    choice.codec = fallback;
    return choice;
}

} // namespace
#endif /* JELLYFIN_HAS_FFMPEG */

struct SoftDecodeSession::Impl {
#if defined(JELLYFIN_HAS_FFMPEG)
    std::unique_ptr<RangeCache> reader;
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
    /** 解码器实际使用的线程数（0 = 解码器自行决定；见 openUrl 里的多核设置） */
    int threadCount = 0;
    /** 选中的解码器名（如 libdav1d / hevc）。宿主与日志据此确认"到底谁在解" */
    std::string decoderName;
    /** 选择解码器时的说明（AV1 是否拿到了 dav1d），用于日志留痕 */
    std::string decoderNote;
    /** 连续被解码器拒绝的包数（用于把"解不出来"尽快变成明确错误，见 nextFrameRgba） */
    int sendRejects = 0;
    /** 最后一包被拒的错误码（AVERROR 负值） */
    int lastSendError = 0;
    std::string error;
#endif
    // ── 阶段跟踪（诊断用；跨线程只读，见 StageSnapshot 的说明）─────────────────
    std::atomic<int> stage{0};
    std::atomic<int64_t> stageStartMs{0};
    std::atomic<int64_t> callStartMs{0};
    std::atomic<int> callPackets{0};

    /**
     * 排队的 seek 目标（秒，<0 表示无请求）。
     * 跨线程访问（UI 线程 requestSeek / 解码线程取用），必须用互斥量保护。
     */
    std::mutex seekMutex;
    double pendingSeekSec = -1.0;
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
    impl_->reader.reset(new RangeCache(url));
    const int64_t size = impl_->reader->probe();
    if (size == 0) {
        error = "取流失败：服务器返回空内容";
        impl_->reader.reset();
        return false;
    }
    // 启动后台预取：让读取路径（宿主的 UI 线程）尽量命中缓存、不做同步网络请求。
    // 设备实测（faultlog）：不预取时逐帧读取会在 UI 线程上做 HTTP，一次往返就把主线程
    // 阻塞 6 秒以上触发 appfreeze —— 根因是"取流发生在 UI 线程"，不是"取流慢"。
    impl_->reader->startPrefetch();
    impl_->bridge.reader = impl_->reader.get();

    constexpr int kAvioBuf = 64 * 1024;
    auto *avioBuf = static_cast<unsigned char *>(av_malloc(kAvioBuf));
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

    DecoderChoice choice = PickVideoDecoder(par->codec_id);
    const AVCodec *codec = choice.codec;
    if (codec == nullptr) {
        error = "本构建不含该视频解码器：" + impl_->codec;
        close();
        return false;
    }
    impl_->decoderNote = choice.note;
    impl_->decoderName = codec->name;
    impl_->dec = avcodec_alloc_context3(codec);
    if (impl_->dec == nullptr || avcodec_parameters_to_context(impl_->dec, par) < 0) {
        error = "打开视频解码器失败：" + impl_->codec;
        close();
        return false;
    }
    // ── 解码效率：让 FFmpeg 用满多核 ──────────────────────────────────────
    // FFmpeg 的软件解码器默认**单线程**（`thread_count = 1`），在 1080p/4K HEVC 上
    // 单核解码就是帧率瓶颈（真机实测软解约 5–10fps，模拟器更低）。
    // `thread_count = 0` 表示"自动"（按 CPU 核数）；`thread_type` 同时请求
    // 帧级与片级并行 —— 解码器会按自身能力取其一（HEVC/H.264 通常支持帧级并行，
    // 能拿到接近线性的多核加速）。两者都必须在 `avcodec_open2()` **之前**设置。
    impl_->dec->thread_count = 0;
    impl_->dec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    // ── OpenHarmony 解码器（ohcodec）需要 allow_sw ─────────────────────────
    // `h264_oh` / `hevc_oh` 默认**只找硬件**编解码器（OH_AVCodec_GetCapabilityByCategory
    // (mime, false, HARDWARE)），找不到就直接报 "Failed to get hardware codec" 打不开。
    // 打开 allow_sw 后，设备没有硬解时会退回系统的**软件**编解码器 ——
    // 这样模拟器与不带该编码硬解的设备也能走通（性能不如硬解，但可用性优先）。
    AVDictionary *openOpts = nullptr;
    if (choice.ohCodec) {
        av_dict_set(&openOpts, "allow_sw", "1", 0);
    }
    int openRc = avcodec_open2(impl_->dec, codec, &openOpts);
    const int firstOpenRc = openRc;
    av_dict_free(&openOpts);
    if (openRc < 0 && choice.ohCodec) {
        // ohcodec 打不开（该设备连系统软编解码器都没有、或系统服务不可用）：
        // 退回 FFmpeg 自带解码器，别让播放直接失败。
        avcodec_free_context(&impl_->dec);
        const AVCodec *fallback = avcodec_find_decoder(par->codec_id);
        if (fallback != nullptr) {
            impl_->dec = avcodec_alloc_context3(fallback);
            if (impl_->dec != nullptr && avcodec_parameters_to_context(impl_->dec, par) >= 0) {
                impl_->dec->thread_count = 0;
                impl_->dec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
                openRc = avcodec_open2(impl_->dec, fallback, nullptr);
                if (openRc >= 0) {
                    impl_->decoderName = fallback->name;
                    // 带上**原始失败原因**（FFmpeg 的错误串）：否则设备上只能看到"打开失败"，
                    // 分不清是"没有该编码的系统编解码器"还是"bitstream filter 缺失"。
                    // FFmpeg 更详细的日志由 player_log.cpp 的 av_log 桥转发到 hilog。
                    impl_->decoderNote = std::string("ohcodec 打开失败（") + AvErrorStr(firstOpenRc) +
                                         "），已退回 " + std::string(fallback->name);
                }
            }
        }
    }
    if (openRc < 0) {
        error = "打开视频解码器失败：" + impl_->codec + "（" + impl_->decoderName + "）";
        close();
        return false;
    }
    impl_->threadCount = impl_->dec->thread_count;
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
    // 排队的 seek 先执行：与解码同线程串行，才不会与 av_read_frame 抢 AVFormatContext；
    // 放在状态判断之前是为了让"已经播到结尾"的会话也能被拉回中间继续播
    // （seek 成功会清掉 eof 标志）。
    {
        double target = -1.0;
        {
            std::lock_guard<std::mutex> lock(impl_->seekMutex);
            if (impl_->pendingSeekSec >= 0.0) {
                target = impl_->pendingSeekSec;
                impl_->pendingSeekSec = -1.0;
            }
        }
        if (target >= 0.0) {
            std::string seekError;
            if (seek(target, seekError)) {
                info.seekApplied = true;
                info.seekedToSec = target;
            } else {
                info.seekError = seekError;
            }
        }
    }
    if (!impl_->open || impl_->failed || impl_->eof) {
        info.error = impl_->error.empty() ? "会话未打开" : impl_->error;
        return false;
    }

    // ── 分段计时：慢在哪一段（取流 / 送包 / 收帧）────────────────────────────
    // 设备实测"解到第 10 帧后某次拉帧 20 秒不返回"，而会话内部当时没有任何耗时日志，
    // 只能靠猜。这里把三段耗时分别累计，只在这帧总耗时 >500ms 时打一行日志。
    const auto frameStart = std::chrono::steady_clock::now();
    impl_->callStartMs.store(NowMs());
    impl_->callPackets.store(0);
    int64_t readMs = 0;
    int64_t sendMs = 0;
    int64_t recvMs = 0;
    int packetsRead = 0;
    // 单次拉帧**长时间不返回**时，也要能在日志里看到它卡在哪一段（否则这种"挂住"只有
    // 宿主的看门狗能发现，诊断信息为零）。每 3 秒打一行进度。
    auto lastStuckReport = frameStart;

    for (;;) {
        const auto recvStart = std::chrono::steady_clock::now();
        impl_->stage.store(static_cast<int>(Stage::ReceiveFrame));
        impl_->stageStartMs.store(NowMs());
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        recvMs += std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - recvStart).count();
        if (rc == 0) {
            break;  // 有帧可用
        }
        if (rc == AVERROR(EAGAIN)) {
            const auto nowTs = std::chrono::steady_clock::now();
            if (std::chrono::duration_cast<std::chrono::seconds>(nowTs - lastStuckReport).count() >= 3) {
                lastStuckReport = nowTs;
                PlayerLog("softDecode stillRunning frame=#" + std::to_string(impl_->frames + 1)
                          + " elapsedMs=" + std::to_string(
                                std::chrono::duration_cast<std::chrono::milliseconds>(nowTs - frameStart).count())
                          + " readMs=" + std::to_string(readMs)
                          + " sendMs=" + std::to_string(sendMs)
                          + " recvMs=" + std::to_string(recvMs)
                          + " packets=" + std::to_string(packetsRead)
                          + " rejects=" + std::to_string(impl_->sendRejects)
                          + " fetched=" + std::to_string(bytesFetched()));
            }
            // 需要更多包
            int readRc = 0;
            const auto readStart = std::chrono::steady_clock::now();
            impl_->stage.store(static_cast<int>(Stage::ReadPacket));
            impl_->stageStartMs.store(NowMs());
            for (;;) {
                readRc = av_read_frame(impl_->fmt, impl_->pkt);
                if (readRc < 0) {
                    break;
                }
                if (impl_->pkt->stream_index == impl_->videoIndex) {
                    packetsRead++;
                    impl_->callPackets.store(packetsRead);
                    break;
                }
                av_packet_unref(impl_->pkt);
            }
            readMs += std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - readStart).count();
            if (readRc < 0) {
                // 数据用完：冲刷解码器
                avcodec_send_packet(impl_->dec, nullptr);
                const int flushRc = avcodec_receive_frame(impl_->dec, impl_->frame);
                if (flushRc == 0) {
                    break;
                }
                // ── "一帧都没解出来就 EOF" 必须当成错误，而不是正常的播放结束 ──────
                // 踩过的坑（AV1 + 自带 av1 解码器）：解码器对**每一个包**都返回
                // -38 ENOSYS，而这里原本把它当"这包没接受、继续读"，于是把整个文件读完、
                // 再以 "eof" 收场 —— 上层看到的是"播放结束"，用户看到的是一块黑屏，
                // 任何一层日志里都没有错误。现在把它变成明确失败。
                if (impl_->frames == 0 && impl_->sendRejects > 0) {
                    impl_->failed = true;
                    impl_->error = "解码器 " + (impl_->decoderName.empty() ? impl_->codec : impl_->decoderName)
                                   + " 拒绝了全部 " + std::to_string(impl_->sendRejects)
                                   + " 个数据包（" + AvErrorStr(impl_->lastSendError) + "），解不出任何帧";
                    info.error = impl_->error;
                    return false;
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
            const auto sendStart = std::chrono::steady_clock::now();
            impl_->stage.store(static_cast<int>(Stage::SendPacket));
            impl_->stageStartMs.store(NowMs());
            const int sendRc = avcodec_send_packet(impl_->dec, impl_->pkt);
            sendMs += std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - sendStart).count();
            if (sendRc < 0) {
                // 记下"被拒绝"的次数与错误码：一帧都没解出来时据此给出可诊断的失败原因
                if (sendRc != AVERROR(EAGAIN)) {
                    impl_->sendRejects++;
                    impl_->lastSendError = sendRc;
                    // 解不出任何帧且已经被拒很多包：立即报错，不再把整片读完（网络与时间都白费）
                    if (impl_->frames == 0 && impl_->sendRejects >= kMaxSendRejects) {
                        impl_->failed = true;
                        impl_->error = "解码器 " + (impl_->decoderName.empty() ? impl_->codec : impl_->decoderName)
                                       + " 无法解码该码流（" + AvErrorStr(sendRc) + "）";
                        info.error = impl_->error;
                        av_packet_unref(impl_->pkt);
                        return false;
                    }
                }
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
    const int64_t frameMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - frameStart).count();
    if (frameMs > 500) {
        PlayerLog("softDecode slowFrame #" + std::to_string(impl_->frames + 1)
                  + " totalMs=" + std::to_string(frameMs)
                  + " readMs=" + std::to_string(readMs)
                  + " sendMs=" + std::to_string(sendMs)
                  + " recvMs=" + std::to_string(recvMs)
                  + " packets=" + std::to_string(packetsRead)
                  + " fetched=" + std::to_string(bytesFetched()));
    }
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
        // 缩放用 FAST_BILINEAR：每帧都要做一次 YUV→RGBA + 缩放，是软解路径里仅次于
        // 解码的第二大开销；高质量双线性在这个尺寸下的观感差异肉眼不可辨，
        // 但省下的 CPU 能直接换成帧率（软解帧率本来就紧）。
        impl_->sws = sws_getContext(srcW, srcH, static_cast<AVPixelFormat>(frame->format), dstW, dstH,
                                    AV_PIX_FMT_RGBA, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
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
    impl_->stage.store(static_cast<int>(Stage::Scale));
    impl_->stageStartMs.store(NowMs());
    sws_scale(impl_->sws, frame->data, frame->linesize, 0, srcH, dstData, dstLinesize);
    impl_->stage.store(static_cast<int>(Stage::Idle));

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
    impl_->stage.store(static_cast<int>(Stage::Idle));
    return true;
#endif
}

bool SoftDecodeSession::seek(double seconds, std::string &error)
{
#if !defined(JELLYFIN_HAS_FFMPEG)
    error = "本构建未链接 FFmpeg";
    return false;
#else
    if (!impl_->open || impl_->failed) {
        error = impl_->error.empty() ? "会话未打开" : impl_->error;
        return false;
    }
    if (impl_->fmt == nullptr || impl_->dec == nullptr || impl_->videoIndex < 0) {
        error = "播放器未就绪";
        return false;
    }
    // 将秒数转换为 AV_TIME_BASE 单位（微秒）
    const auto targetTs = static_cast<int64_t>(seconds * AV_TIME_BASE);
    // AVSEEK_FLAG_BACKWARD：向后 seek 到最近的关键帧（标准做法）
    const int rc = av_seek_frame(impl_->fmt, -1, targetTs, AVSEEK_FLAG_BACKWARD);
    if (rc < 0) {
        error = "seek 失败：" + AvErrorStr(rc);
        return false;
    }
    // 冲刷解码器缓冲：seek 后解码器里残留的旧帧必须清掉，
    // 否则 nextFrameRgba 会先输出几帧旧数据才到目标位置
    avcodec_flush_buffers(impl_->dec);
    // 重置 EOF 标志：seek 回中间位置后流还有数据
    impl_->eof = false;
    return true;
#endif
}

void SoftDecodeSession::requestSeek(double seconds)
{
    if (seconds < 0.0) {
        seconds = 0.0;
    }
    std::lock_guard<std::mutex> lock(impl_->seekMutex);
    impl_->pendingSeekSec = seconds;
}

void SoftDecodeSession::close()
{
#if defined(JELLYFIN_HAS_FFMPEG)
    // 先停预取线程再释放读取器：否则后台线程可能正在用已析构的对象取流
    if (impl_->reader) {
        impl_->reader->stopPrefetch();
    }
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
    impl_->decoderName.clear();
    impl_->decoderNote.clear();
    impl_->sendRejects = 0;
    impl_->lastSendError = 0;
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

int SoftDecodeSession::decoderThreads() const
{
    return impl_->threadCount;
}

SoftDecodeSession::StageSnapshot SoftDecodeSession::stageSnapshot() const
{
    StageSnapshot snapshot;
    snapshot.stage = static_cast<Stage>(impl_->stage.load());
    const int64_t now = NowMs();
    const int64_t stageStart = impl_->stageStartMs.load();
    const int64_t callStart = impl_->callStartMs.load();
    snapshot.stageMs = (snapshot.stage == Stage::Idle || stageStart == 0) ? 0 : (now - stageStart);
    snapshot.callMs = callStart == 0 ? 0 : (now - callStart);
    snapshot.packetsRead = impl_->callPackets.load();
    snapshot.sendRejects = impl_->sendRejects;
    snapshot.frames = impl_->frames;
    snapshot.bytesFetched = bytesFetched();
    return snapshot;
}

const std::string &SoftDecodeSession::decoderName() const
{
    return impl_->decoderName;
}

const std::string &SoftDecodeSession::decoderNote() const
{
    return impl_->decoderNote;
}

} // namespace player
} // namespace jellyfin
