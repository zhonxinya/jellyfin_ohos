#ifndef JELLYFIN_CORE_JSON_DUMP_H
#define JELLYFIN_CORE_JSON_DUMP_H

#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {

/**
 * 容错 JSON 序列化：非法 UTF-8 字节替换为 U+FFFD，**绝不抛异常**。
 *
 * ## 为什么不能用裸 `dump()`
 *
 * nlohmann 的 `dump()` **默认**的 `error_handler_t` 是 `strict`：遇到非法 UTF-8
 * 直接抛 `type_error.316`。本机实测（nlohmann 3.11.3）两种形态都会触发：
 *
 * | 输入 | `dump()` |
 * |---|---|
 * | `"Movie \xE4\xB8"`（截断的多字节序列） | 抛 `incomplete UTF-8 string; last byte: 0xB8` |
 * | `"\x80\x80"`（孤立的续字节） | 抛 `invalid UTF-8 byte at index 0: 0x80` |
 * | 同上，但用 `error_handler_t::replace` | 正常返回，非法字节显示为 `�` |
 *
 * ## 为什么这里"一定会遇到"非法 UTF-8
 *
 * 进 JSON 的文本有两个**客户端控制不了**的来源：
 * 1. **服务端返回的媒体名 / 路径 / 错误消息** —— 不同服务器、不同文件系统编码下
 *    可能带非法字节，或响应被截断在多字节序列中间；
 * 2. **服务端返回的字幕文件内容** —— GBK 编码的 `.srt` 在本工程是常见场景，它**不是**
 *    合法 UTF-8。
 *
 * ## 抛出去的后果（两种都不该发生）
 *
 * - **同步** NAPI 出口（`ToNapiJson`）抛 → 应用**直接消失**，没有栈、没有日志；
 * - **异步**出口（`RunAsync`）抛 → 被最后一道防线转成"操作失败"，把**本来可用**的结果
 *   变成报错 —— 用户看日志 / 看字幕时最需要的恰恰是原始内容。
 *
 * 替换成 U+FFFD 只让那几个字节显示成 `�`，信息量损失最小。
 *
 * 注意与"类型不符"（`type_error.302`）区分：那个由**容错读取**解决（见 `json_arg.h`）。
 *
 * 本函数是 header-only 纯函数，可在主机上直接单测
 * （`native/core/tests/test_json_arg.cpp`，用真实非法字节断言）。
 */
inline std::string SafeDumpJson(const nlohmann::json &j)
{
    return j.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_JSON_DUMP_H */
