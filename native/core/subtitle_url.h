#ifndef JELLYFIN_CORE_SUBTITLE_URL_H
#define JELLYFIN_CORE_SUBTITLE_URL_H

#include <string>

namespace jellyfin {

/**
 * 构造"外挂字幕"文件地址（Jellyfin 字幕端点）。
 *
 * 路径形态：`/Videos/{itemId}/{mediaSourceId}/Subtitles/{streamIndex}/Stream.{format}`
 *
 * 为什么需要它：播放中切换字幕有两条路——
 * 1）服务端在转码/直传时把字幕烧进画面（需要重开播放会话，会断开播放）；
 * 2）客户端把字幕当**外挂字幕文件**取回来交给播放器叠加（不中断播放）。
 * 本函数服务于第 2 条：把选中的字幕流取成一个播放器可直接加载的 URL。
 *
 * Jellyfin 会在服务端按 `format` 转换文本字幕（实测 ass/srt/vtt 均可直接取回），
 * 因此调用方可以统一按兼容性最好的格式（vtt）请求，而不必迁就源字幕编码。
 */
std::string BuildSubtitleUrl(const std::string &baseUrl, const std::string &itemId,
                             const std::string &mediaSourceId, int streamIndex,
                             const std::string &format, const std::string &accessToken);

/**
 * 字幕编码 → 请求格式。
 *
 * 文本型（srt/ass/ssa/mov_text/…）统一请求 `vtt`：WebVTT 是播放器支持面最广的文本字幕格式，
 * 且服务端转换无需重编码视频。
 * 图形型（PGS/SUP/VOBSUB/DVB）**无法**转成文本，只能按原编码取回（能否显示取决于播放器）。
 */
std::string SubtitleFormatForCodec(const std::string &codec);

/** 该字幕编码是否为图形字幕（位图，不是文本；客户端外挂渲染通常不支持） */
bool IsImageSubtitleCodec(const std::string &codec);

} // namespace jellyfin

#endif /* JELLYFIN_CORE_SUBTITLE_URL_H */
