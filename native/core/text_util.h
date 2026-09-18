#ifndef JELLYFIN_CORE_TEXT_UTIL_H
#define JELLYFIN_CORE_TEXT_UTIL_H

#include <cstddef>
#include <string>

namespace jellyfin {

/** UTF-8 续字节（10xxxxxx） */
inline bool IsUtf8ContinuationByte(unsigned char byte)
{
    return (byte & 0xC0u) == 0x80u;
}

/**
 * 取文本末尾 `keepTailBytes` 字节。
 *
 * 用途：服务端日志（`GET /System/Logs/Log`）动辄十几 MB，而服务端**没有**
 * range/tail 端点，手机端把整份读出来再交给 UI 会白白占几十 MB。
 * 这一层把整份响应裁成"最后一小段"，交给 ArkTS 的字符串就很小了。
 *
 * 两个细节：
 * - 按**字节**切，但会往前退到合法的 UTF-8 边界，避免最后一行开头出现乱码；
 * - 从第一个换行之后开始返回，避免首行是个半句话。
 *
 * `truncated` 会在确实截断时置 true（界面据此提示"只显示最后 N KB"）。
 */
inline std::string TailBytes(const std::string &text, std::size_t keepTailBytes, bool &truncated)
{
    truncated = false;
    if (keepTailBytes == 0 || text.size() <= keepTailBytes) {
        return text;
    }
    std::size_t start = text.size() - keepTailBytes;
    // 退到 UTF-8 字符边界
    std::size_t guard = 0;
    while (start < text.size() && IsUtf8ContinuationByte(static_cast<unsigned char>(text[start])) &&
           guard < 3) {
        ++start;
        ++guard;
    }
    // 退到第一个换行之后，避免首行是半句话
    const std::size_t newline = text.find('\n', start);
    if (newline != std::string::npos && newline + 1 < text.size()) {
        start = newline + 1;
    }
    truncated = true;
    return text.substr(start);
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_TEXT_UTIL_H */
