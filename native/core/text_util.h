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
 * 取 `text[pos]` 处那个 UTF-8 序列的长度；非法/被截断时返回 0。
 *
 * 按 RFC 3629 严格判定（不是"看着像就算"）：过长编码（C0/C1、E0 80、F0 80）、
 * 代理区（ED A0..，即 U+D800..U+DFFF）和超出 U+10FFFF（F4 90..、F5..FF）都算非法 ——
 * 这些字节序列在标准解析器（含 nlohmann、ICU）里都会被拒。
 */
inline std::size_t Utf8SequenceLength(const std::string &text, std::size_t pos)
{
    // 用 auto 承接转换结果：与工程既有写法一致，也避开 clang-tidy 的 modernize-use-auto
    const auto first = static_cast<unsigned char>(text[pos]);
    if (first < 0x80u) {
        return 1;
    }

    std::size_t continuationCount = 0;
    unsigned char secondLow = 0x80u;
    unsigned char secondHigh = 0xBFu;
    if (first >= 0xC2u && first <= 0xDFu) {
        continuationCount = 1;
    } else if (first >= 0xE0u && first <= 0xEFu) {
        continuationCount = 2;
        if (first == 0xE0u) {
            secondLow = 0xA0u; // 拒绝过长编码
        } else if (first == 0xEDu) {
            secondHigh = 0x9Fu; // 拒绝代理区
        }
    } else if (first >= 0xF0u && first <= 0xF4u) {
        continuationCount = 3;
        if (first == 0xF0u) {
            secondLow = 0x90u; // 拒绝过长编码
        } else if (first == 0xF4u) {
            secondHigh = 0x8Fu; // 拒绝超出 U+10FFFF
        }
    } else {
        return 0;
    }

    if (pos + continuationCount >= text.size()) {
        return 0; // 被截断在多字节序列中间
    }
    const auto second = static_cast<unsigned char>(text[pos + 1]);
    if (second < secondLow || second > secondHigh) {
        return 0;
    }
    for (std::size_t i = 2; i <= continuationCount; ++i) {
        if (!IsUtf8ContinuationByte(static_cast<unsigned char>(text[pos + i]))) {
            return 0;
        }
    }
    return continuationCount + 1;
}

/** 整串是否为合法 UTF-8 */
inline bool IsValidUtf8(const std::string &text)
{
    std::size_t pos = 0;
    while (pos < text.size()) {
        const std::size_t length = Utf8SequenceLength(text, pos);
        if (length == 0) {
            return false;
        }
        pos += length;
    }
    return true;
}

/**
 * 非法 UTF-8 字节替换成 U+FFFD（`EF BF BD`），**绝不抛异常**；合法文本原样返回。
 *
 * ## 为什么解析响应体前必须先过一遍这里
 *
 * nlohmann 的 `json::parse()` 对非法 UTF-8 是**抛异常**（本机实测 nlohmann 3.11.3：
 * GBK 字节 `\xB2\xE2\xCA\xD4` 抛 `parse_error.101 ... ill-formed UTF-8 byte`），
 * 与 `dump()` 的 `error_handler_t::replace` 不同 —— **parse 没有容错档位**。
 *
 * 而服务端文本里出现非法 UTF-8 是真实场景（音乐标签是 GBK 的曲目、GBK 字幕文件、
 * 截断在多字节中间的响应），`api_client.cpp` 的 `interpret()` 一旦在 `parse()` 上抛，
 * 整份响应就退化成 "JSON parse error"：**一个曲目的名字乱码，整个音乐库/首页都打不开**。
 * 用户要的是"能看见其余内容、只有那一个名字显示成 �"。
 *
 * 这与 `json_dump.h` 的 `SafeDumpJson()`（写出方向：非法字节 → U+FFFD）是同一策略的两端：
 * 读入方向也必须在进 JSON 之前把非法字节收敛掉。替换成 U+FFFD 只损失那几个字节的信息量，
 * 是这里能做到的最小代价。
 *
 * 纯函数、header-only，可主机单测（`native/core/tests/test_text_repair.cpp`，用真实字节断言）。
 */
inline std::string SanitizeUtf8(const std::string &text)
{
    if (IsValidUtf8(text)) {
        return text;
    }
    std::string out;
    out.reserve(text.size());
    std::size_t pos = 0;
    while (pos < text.size()) {
        const std::size_t length = Utf8SequenceLength(text, pos);
        if (length == 0) {
            out.append("\xEF\xBF\xBD");
            ++pos;
            continue;
        }
        out.append(text, pos, length);
        pos += length;
    }
    return out;
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
