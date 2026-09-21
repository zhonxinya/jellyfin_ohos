#ifndef JELLYFIN_CORE_JSON_ARG_H
#define JELLYFIN_CORE_JSON_ARG_H

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace json_arg {

/**
 * 从 JSON 里**容错**读取入参（字符串 / 整数 / 布尔）。
 *
 * ## 为什么需要这三个函数（不是随手封装的糖）
 *
 * `nlohmann::json::value(key, default)` 只在"键不存在"时返回 default ——
 * **键存在但类型不符会直接抛 `type_error.302`**。这一点很容易被误当成"已经给了默认值、
 * 一定是安全的"，实测（nlohmann 3.11.3）：
 *
 * | JSON | `j.value("k", <默认>)` |
 * |---|---|
 * | `{}` | 返回默认值 ✅ |
 * | `{"k": null}` | **抛异常** ❌ |
 * | `{"k": "50"}`（期望数字） | **抛异常** ❌ |
 *
 * 而在 NAPI 边界上，"类型不符"是**常态**而不是异常：
 * 1. ArkTS 的 `JSON.stringify()` 会把对象字段里的 `null` 原样保留、`undefined` 省略 ——
 *    前端漏写一个字段就是一次未捕获异常；
 * 2. JSON 的大整数（例如 `Ticks`）在 JS 侧会退化成字符串；
 * 3. 服务端版本差异下同一个字段可能是数字也可能是字符串（本工程已按"不要假设所有
 *    Jellyfin 服务器启用相同功能"的约定兼容旧版本响应）。
 *
 * 而异常一旦从 `RunAsync` 的 worker 线程逸出，libuv 由 C 编写、不会捕获 C++ 异常，
 * `std::terminate()` 会**直接终止整个应用**（本机已用最小探针复现：
 * 在 pthread 入口抛异常 → `std::terminate`）。
 *
 * ## 为什么放在 core 而不是 napi
 *
 * 同一套容错语义在 core 的 API 层（解析服务端响应）同样适用，放 core 可以两边共用；
 * 且它是**头文件内的纯函数、不依赖 NAPI/HTTP**，因此可以主机单测
 * （`native/core/tests/test_json_arg.cpp`），不必把 NAPI 拖进单测编译。
 *
 * 既有代码里的 `JsonStringField()`（napi）与各处 `contains() && is_string()` 保护
 * 都是同一意图，本文件只是把它收敛成可复用、可测试的一处。
 */

/**
 * 取字符串字段。
 *
 * @return 字段存在且是字符串时返回它；否则返回 `fallback`
 *         （字段不存在 / 为 `null` / 是数字或对象 / 顶层不是对象，都走这条）
 */
inline std::string String(const nlohmann::json &obj, const char *key,
                          const std::string &fallback = std::string())
{
    if (!obj.is_object()) {
        return fallback;
    }
    const auto it = obj.find(key);
    if (it == obj.end() || !it->is_string()) {
        return fallback;
    }
    return it->get<std::string>();
}

/**
 * 取整数字段。
 *
 * 比 `String()` 多两种宽容：字符串形式的数字会被解析（见文件头第 2 条），
 * 浮点会被截断。溢出、非数字字符串、`null`、类型不符一律返回 `fallback`。
 */
inline long long Int(const nlohmann::json &obj, const char *key, long long fallback)
{
    if (!obj.is_object()) {
        return fallback;
    }
    const auto it = obj.find(key);
    if (it == obj.end() || it->is_null()) {
        return fallback;
    }
    // 先判 unsigned：nlohmann 的 is_number_integer() 对无符号也返回 true，
    // 而 get<long long>() 对超出 long long 范围的 unsigned 会抛。
    if (it->is_number_unsigned()) {
        const unsigned long long value = it->get<unsigned long long>();
        if (value > static_cast<unsigned long long>(std::numeric_limits<long long>::max())) {
            return fallback;
        }
        return static_cast<long long>(value);
    }
    if (it->is_number_integer()) {
        return it->get<long long>();
    }
    if (it->is_number_float()) {
        const double number = it->get<double>();
        // NaN / inf 转成整数是未定义行为，直接判为不可用
        if (!std::isfinite(number)) {
            return fallback;
        }
        if (number > static_cast<double>(std::numeric_limits<long long>::max()) ||
            number < static_cast<double>(std::numeric_limits<long long>::min())) {
            return fallback;
        }
        return static_cast<long long>(number);
    }
    if (it->is_string()) {
        const std::string text = it->get<std::string>();
        if (text.empty()) {
            return fallback;
        }
        errno = 0;
        char *end = nullptr;
        const long long value = std::strtoll(text.c_str(), &end, 10);
        // 必须整串都是数字：否则 "50abc" / "1.5" 会被静默截断成看似合理的值。
        if (errno != 0 || end == text.c_str() || *end != '\0') {
            return fallback;
        }
        return value;
    }
    return fallback;
}

/**
 * 取 `int` 字段：内部走 `Int()`，但会**先判界再窄化**。
 *
 * 为什么不直接 `static_cast<int>(Int(...))`：越界是回绕截断，而本工程的这些 int 字段
 * 回绕后可能变成**合法但错误**的值（`limit` 变负、`AudioStreamIndex` 从大正数变成 -1
 * 即"未指定"），静默改变请求语义与服务端行为，排查时完全看不出根因。越界一律回落默认值。
 */
inline int Int32(const nlohmann::json &obj, const char *key, int fallback)
{
    const long long value = Int(obj, key, static_cast<long long>(fallback));
    if (value > static_cast<long long>(std::numeric_limits<int>::max()) ||
        value < static_cast<long long>(std::numeric_limits<int>::min())) {
        return fallback;
    }
    return static_cast<int>(value);
}

/** 取布尔字段；只接受真正的 JSON 布尔，其余（含数字）一律返回 `fallback` */
inline bool Bool(const nlohmann::json &obj, const char *key, bool fallback)
{
    if (!obj.is_object()) {
        return fallback;
    }
    const auto it = obj.find(key);
    if (it == obj.end() || !it->is_boolean()) {
        return fallback;
    }
    return it->get<bool>();
}

} // namespace json_arg
} // namespace jellyfin

#endif /* JELLYFIN_CORE_JSON_ARG_H */
