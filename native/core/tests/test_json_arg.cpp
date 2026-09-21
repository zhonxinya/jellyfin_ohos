/**
 * Host-side unit tests for json_arg（入参容错读取）与 json_dump（容错序列化）。
 *
 * 两个头文件守的是同一条硬约束的两端：**任何 JSON 操作都不得让异常逸出到 NAPI 边界**
 * ——读入参用 `json_arg`（`value()` 对"键存在但类型不符"会抛 `type_error.302`），
 * 写出结果用 `SafeDumpJson`（`dump()` 对非法 UTF-8 会抛 `type_error.316`）。
 *
 * 为什么值得单测：三个读取函数守着的是"**异常不得从 NAPI 边界逸出**"这条硬约束。
 * `nlohmann::json::value(key, default)` 在"键存在但类型不符"时会抛 `type_error.302`
 * （键不存在才返回默认值），而 ArkTS 的 `JSON.stringify` 会把字段里的 `null` 原样带过来 ——
 * 异常一旦从 RunAsync 的 worker 线程逸出就是 `std::terminate()`、应用直接消失。
 * 这类失败在设备上表现为"某个页面莫名退出"，很难回推到"某次参数读取"，
 * 所以在这里把语义钉死。
 *
 * Build (from repo root):
 *   g++ -std=c++17 -I native/core -I native/third_party native/core/tests/test_json_arg.cpp \
 *       -o test_json_arg
 */

#include "json_arg.h"
#include "json_dump.h"

#include <iostream>
#include <limits>
#include <string>

using jellyfin::json_arg::Bool;
using jellyfin::json_arg::Int;
using jellyfin::json_arg::Int32;
using jellyfin::json_arg::String;

namespace {

int gFailures = 0;

void Expect(bool condition, const std::string &name, const std::string &detail = std::string())
{
    if (condition) {
        std::cout << "ok   " << name << "\n";
    } else {
        std::cerr << "FAIL " << name;
        if (!detail.empty()) {
            std::cerr << " -> " << detail;
        }
        std::cerr << "\n";
        ++gFailures;
    }
}

/** 解析一段 JSON 文本（模拟宿主传来的参数串） */
nlohmann::json Parse(const char *text)
{
    return nlohmann::json::parse(text);
}

/**
 * 核心回归：**绝不能抛异常**。
 *
 * 枚举所有"类型不符"的形态，只要有一个抛出去，整条用例集就会在此中断 ——
 * 这本身就是断言（真正的 crash 比一个 FAIL 行更强）。
 */
void TestNeverThrowsOnMismatchedTypes()
{
    const char *samples[] = {
        R"({})",
        R"({"k":null})",
        R"({"k":""})",
        R"({"k":"50"})",
        R"({"k":"abc"})",
        R"({"k":"1.5"})",
        R"({"k":50})",
        R"({"k":-1})",
        R"({"k":1.5})",
        R"({"k":true})",
        R"({"k":false})",
        R"({"k":[]})",
        R"({"k":{}})",
        R"({"k":[1,2]})",
        R"({"k":18446744073709551615})",
        R"("not-an-object")",
        R"([1,2,3])",
        R"(null)",
        R"(123)",
    };

    // 超出 double 范围的字面量（1e400）会在 `json::parse()` 阶段就抛 out_of_range.406，
    // 不归 json_arg 管 —— 在 parse 与 json_arg 之间那段 try/catch 的边界一并用例守住，
    // 否则这条会绕过"绝不抛异常"的断言（本机实测：漏掉 catch 时进程直接 abort）。
    bool parseThrew = false;
    try {
        const nlohmann::json overflow = nlohmann::json::parse(R"({"k":1e400})");
        (void)overflow;
    } catch (const std::exception &) {
        parseThrew = true;
    }
    Expect(parseThrew,
           "超出 double 范围的字面量在 parse 阶段抛（调用方必须用自己的 try/catch 兜住）");

    bool threw = false;
    std::string thrownFrom;
    for (const char *sample : samples) {
        const nlohmann::json j = Parse(sample);
        try {
            (void)String(j, "k", "fallback");
            (void)Int(j, "k", -7);
            (void)Bool(j, "k", true);
            (void)String(j, "missing", "fallback");
            (void)Int(j, "missing", -7);
            (void)Bool(j, "missing", true);
        } catch (const std::exception &e) {
            threw = true;
            thrownFrom = std::string(sample) + " -> " + e.what();
        }
    }
    Expect(!threw, "任何类型不符的输入都不抛异常（异常逸出 worker 线程 = 进程被杀）",
           thrownFrom);
}

void TestStringSemantics()
{
    Expect(String(Parse(R"({"k":"v"})"), "k", "fb") == "v", "字符串按原值返回");
    Expect(String(Parse(R"({"k":""})"), "k", "fb").empty(),
           "空字符串是存在且为字符串，返回空串而不是 fallback");
    Expect(String(Parse(R"({})"), "k", "fb") == "fb", "字段缺失返回 fallback");
    Expect(String(Parse(R"({"k":null})"), "k", "fb") == "fb",
           "null 返回 fallback（这正是 value() 会抛的那种输入）");
    Expect(String(Parse(R"({"k":50})"), "k", "fb") == "fb", "数字不隐式转字符串");
    Expect(String(Parse(R"({"k":true})"), "k", "fb") == "fb", "布尔不隐式转字符串");
    Expect(String(Parse(R"([1,2])"), "k", "fb") == "fb", "顶层不是对象时返回 fallback");
    Expect(String(Parse(R"(null)"), "k", "fb") == "fb", "顶层是 null 时返回 fallback");
}

void TestIntSemantics()
{
    Expect(Int(Parse(R"({"k":50})"), "k", -1) == 50, "JSON 整数直接取");
    Expect(Int(Parse(R"({"k":-3})"), "k", -1) == -3, "负整数可读");
    Expect(Int(Parse(R"({"k":0})"), "k", -1) == 0, "0 是合法值（与「缺失」不会混淆）");
    Expect(Int(Parse(R"({"k":null})"), "k", -1) == -1, "null 返回 fallback");
    Expect(Int(Parse(R"({"k":true})"), "k", -1) == -1, "布尔不当作 1/0");
    Expect(Int(Parse(R"({"k":{}})"), "k", -1) == -1, "对象返回 fallback");

    // 字符串形式的数字：Ticks 这类大整数经 JS 传递时会退化成字符串，必须能读回来。
    Expect(Int(Parse(R"({"k":"50"})"), "k", -1) == 50, "字符串数字可解析");
    Expect(Int(Parse(R"({"k":"-12"})"), "k", -1) == -12, "负数字符串可解析");
    Expect(Int(Parse(R"({"k":"abc"})"), "k", -1) == -1, "非数字字符串返回 fallback");
    Expect(Int(Parse(R"({"k":"1.5"})"), "k", -1) == -1,
           "小数形式的字符串（Ticks 不该出现）返回 fallback，不做静默截断");
    Expect(Int(Parse(R"({"k":"50abc"})"), "k", -1) == -1,
           "尾部有杂字符的字符串返回 fallback，不静默取前半段");
    Expect(Int(Parse(R"({"k":""})"), "k", -1) == -1, "空字符串返回 fallback");

    // 浮点：截断；非有限值拒绝。
    Expect(Int(Parse(R"({"k":2.9})"), "k", -1) == 2, "浮点截断为整数");
    Expect(Int(Parse(R"({"k":-2.9})"), "k", -1) == -2, "负浮点截断为整数");

    // 边界
    const long long maxLl = std::numeric_limits<long long>::max();
    Expect(Int(Parse(R"({"k":9223372036854775807})"), "k", -1) == maxLl,
           "long long 上界可读");
    Expect(Int(Parse(R"({"k":9223372036854775808})"), "k", -1) == -1,
           "超出 long long 的 JSON 整数返回 fallback");
    Expect(Int(Parse(R"({"k":-1e19})"), "k", -1) == -1,
           "远低于 long long 下界的浮点返回 fallback");
    // 注：不用 -9223372036854775809 做这条断言 —— 它超出 int64 会被 nlohmann 存成 double，
    // 而 double 在该量级无法区分 -9223372036854775809 与 LONG_LONG_MIN，
    // 于是会（无害地）返回下界值。断言写成"必须 fallback"就是断言了一件 double 做不到的事。
    Expect(Int(Parse(R"({"k":18446744073709551615})"), "k", -1) == -1,
           "unsigned 上界（超 long long 范围）返回 fallback 而不是抛异常");

    // inf / NaN：parse 本身产不出（见 TestNeverThrowsOnMismatchedTypes 的 1e400 说明），
    // 但内存里构造得出来（例如由某个 double 计算结果赋值进来），仍必须安全。
    nlohmann::json nonFinite;
    nonFinite["k"] = std::numeric_limits<double>::infinity();
    Expect(Int(nonFinite, "k", -1) == -1,
           "inf 返回 fallback（转整数是未定义行为）");
    nonFinite["k"] = std::numeric_limits<double>::quiet_NaN();
    Expect(Int(nonFinite, "k", -1) == -1, "NaN 返回 fallback");
}

void TestBoolSemantics()
{
    Expect(Bool(Parse(R"({"k":true})"), "k", false) == true, "true 可读");
    Expect(Bool(Parse(R"({"k":false})"), "k", true) == false,
           "false 可读（与「字段缺失取 fallback」不会混淆）");
    Expect(Bool(Parse(R"({})"), "k", true) == true, "字段缺失返回 fallback");
    Expect(Bool(Parse(R"({"k":null})"), "k", true) == true, "null 返回 fallback");
    Expect(Bool(Parse(R"({"k":1})"), "k", false) == false,
           "数字 1 不当作 true（保持与 value() 一致的严格语义）");
    Expect(Bool(Parse(R"({"k":"true"})"), "k", false) == false,
           "字符串 true（带引号）不当作 true");
    Expect(Bool(Parse(R"([1])"), "k", false) == false, "顶层不是对象时返回 fallback");
}

/** `Object()`：拿不到对象就给空对象，绝不抛异常 */
void TestObjectSemantics()
{
    using jellyfin::json_arg::Object;

    Expect(Object(Parse(R"({"k":{"a":1}})"), "k").is_object() &&
               Object(Parse(R"({"k":{"a":1}})"), "k")["a"] == 1,
           "对象字段照常返回");
    Expect(Object(Parse(R"({"k":{}})"), "k").is_object() &&
               Object(Parse(R"({"k":{}})"), "k").empty(),
           "空对象是合法值（返回空对象而不是 fallback 之外的形状）");
    Expect(Object(Parse(R"({})"), "k").is_object(), "字段缺失返回空对象");
    Expect(Object(Parse(R"({"k":null})"), "k").is_object(),
           "null 返回空对象（这正是 value() 会抛的输入）");
    Expect(Object(Parse(R"({"k":[]})"), "k").is_object(), "数组返回空对象");
    Expect(Object(Parse(R"({"k":"s"})"), "k").is_object(), "字符串返回空对象");
    Expect(Object(Parse(R"({"k":7})"), "k").is_object(), "数字返回空对象");

    // 记录 nlohmann 的真实行为（实测）：default 也是 json 时 value() **不做**类型检查，
    // 因此这几种输入不会抛。Object() 的价值是把"拿不到对象就用空对象"收在一处，
    // 而不是修一个会抛的 bug —— 断言如实写下这一点，避免后人误以为是防崩措施。
    bool valueThrew = false;
    try {
        (void)Parse(R"({"k":[]})").value("k", nlohmann::json::object());
        (void)Parse(R"({"k":null})").value("k", nlohmann::json::object());
    } catch (const std::exception &) {
        valueThrew = true;
    }
    Expect(!valueThrew,
           "对照：value(k, json::object()) 对数组/null 不抛（Object() 主要收益是语义收敛）");

    // 而 default 为**具体类型**时 value() 确实会抛 —— 这才是必须用 Bool()/Int() 的原因。
    bool concreteThrew = false;
    try {
        (void)Parse(R"({"k":null})").value("k", false);
    } catch (const std::exception &) {
        concreteThrew = true;
    }
    Expect(concreteThrew, "对照：value(k, false) 对 null 会抛（Bool() 因此存在）");
}

/**
 * `Int32()`：越界必须回落默认值，**不能回绕**。
 *
 * 为什么单独守这条：两个宿主的选项解析（ItemsQuery / PlaybackInfoOptions）都用它，
 * 而那些 int 字段回绕后会变成"合法但错误"的值 —— 负的 `limit` 会被拼进请求参数、
 * 超大的 `AudioStreamIndex` 会变成 -1（= 未指定音轨），静默改变服务端行为，
 * 从现象完全看不出根因。
 */
void TestInt32DoesNotWrapAround()
{
    const int intMax = std::numeric_limits<int>::max();
    const int intMin = std::numeric_limits<int>::min();

    Expect(Int32(Parse(R"({"k":50})"), "k", 7) == 50, "范围内整数正常取值");
    Expect(Int32(Parse(R"({"k":0})"), "k", 7) == 0, "0 是合法值");
    Expect(Int32(Parse(R"({"k":-1})"), "k", 7) == -1,
           "-1 是合法值（本工程用它表示「未指定」）");
    Expect(Int32(Parse(R"({"k":null})"), "k", 7) == 7, "null 回落默认值");
    Expect(Int32(Parse(R"({"k":"abc"})"), "k", 7) == 7, "非数字字符串回落默认值");
    Expect(Int32(Parse(R"({})"), "k", 7) == 7, "字段缺失回落默认值");

    // 边界：恰好等于 int 上下界时可取。
    const std::string atMax = std::string("{\"k\":") + std::to_string(intMax) + "}";
    const std::string atMin = std::string("{\"k\":") + std::to_string(intMin) + "}";
    Expect(Int32(Parse(atMax.c_str()), "k", 7) == intMax, "恰好等于 int 上界时可取");
    Expect(Int32(Parse(atMin.c_str()), "k", 7) == intMin, "恰好等于 int 下界时可取");

    // 越界：不能回绕。旧写法 static_cast<int>(long long) 在这里会给出错误但"看着合理"的值。
    const long long aboveMax = static_cast<long long>(intMax) + 1;
    const long long belowMin = static_cast<long long>(intMin) - 1;
    const std::string overMax = std::string("{\"k\":") + std::to_string(aboveMax) + "}";
    const std::string underMin = std::string("{\"k\":") + std::to_string(belowMin) + "}";
    Expect(Int32(Parse(overMax.c_str()), "k", 7) == 7,
           "略超 int 上界 → 回落默认值（不回绕成负数）");
    Expect(Int32(Parse(underMin.c_str()), "k", 7) == 7,
           "略低于 int 下界 → 回落默认值（不回绕成正数）");
    Expect(Int32(Parse(R"({"k":4294967296})"), "k", 7) == 7,
           "2^32（回绕后为 0）→ 回落默认值，而不是静默变成 0");
}

/**
 * `SafeDumpJson()`：非法 UTF-8 必须被替换成 U+FFFD，**不能抛异常**。
 *
 * 为什么这是真实风险而不是理论问题：进 JSON 的文本有两个客户端控制不了的来源 ——
 * 服务端返回的媒体名/路径/错误消息，以及**字幕文件内容**（GBK 编码的 .srt 在本工程
 * 是常见场景，它不是合法 UTF-8）。裸 `dump()` 的默认 handler 是 strict，会抛
 * `type_error.316`：在同步 NAPI 出口就是应用直接消失，在异步出口会把"取到了字幕/日志"
 * 变成"操作失败"。
 *
 * 下面每条断言里的字节都是**真实形态**（截断的多字节序列、孤立续字节），不是编造的。
 */
void TestSafeDumpToleratesInvalidUtf8()
{
    // 1) 对照组：裸 dump() 对同样的输入确实会抛 —— 这就是 SafeDumpJson 存在的理由。
    nlohmann::json truncated;
    truncated["Name"] = std::string("Movie \xE4\xB8"); // "中"的前两字节（截断）
    bool rawThrew = false;
    try {
        (void)truncated.dump();
    } catch (const std::exception &) {
        rawThrew = true;
    }
    Expect(rawThrew, "对照组：裸 dump() 对截断的多字节序列确实会抛（本函数因此存在）");

    nlohmann::json stray;
    stray["Name"] = std::string("\x80\x80"); // 孤立续字节
    rawThrew = false;
    try {
        (void)stray.dump();
    } catch (const std::exception &) {
        rawThrew = true;
    }
    Expect(rawThrew, "对照组：裸 dump() 对孤立续字节确实会抛");

    // 2) SafeDumpJson 对同样输入必须安全，且输出仍是合法 JSON 文本。
    std::string out;
    bool threw = false;
    try {
        out = jellyfin::SafeDumpJson(truncated);
    } catch (const std::exception &) {
        threw = true;
    }
    Expect(!threw, "SafeDumpJson 对截断序列不抛异常");
    Expect(!out.empty(), "SafeDumpJson 仍返回文本");
    // 输出必须能被重新解析回来（说明替换后的仍是合法 UTF-8 JSON）
    bool reparsed = true;
    try {
        const nlohmann::json back = nlohmann::json::parse(out);
        reparsed = back.contains("Name") && back["Name"].is_string();
    } catch (const std::exception &) {
        reparsed = false;
    }
    Expect(reparsed, "SafeDumpJson 的输出可被重新解析（替换后的字节是合法 UTF-8）");

    threw = false;
    try {
        out = jellyfin::SafeDumpJson(stray);
    } catch (const std::exception &) {
        threw = true;
    }
    Expect(!threw, "SafeDumpJson 对孤立续字节不抛异常");

    // 3) 非法字节应显示为 U+FFFD（"\xEF\xBF\xBD"），而不是被静默丢掉或变成其他字符。
    Expect(out.find("\xEF\xBF\xBD") != std::string::npos,
           "非法字节被替换成 U+FFFD（界面上显示为 ?，信息不丢位置）");

    // 4) 合法 UTF-8（含中文）不受影响 —— 容错不能改变正常内容的编码。
    nlohmann::json chinese;
    chinese["Name"] = std::string("流浪地球2");
    const std::string dumped = jellyfin::SafeDumpJson(chinese);
    Expect(dumped.find("流浪地球2") != std::string::npos,
           "合法中文不受影响（逐字节保留）");

    // 5) 字幕这种大段文本的真实形态：GBK 字节流。
    nlohmann::json subtitle;
    subtitle["text"] = std::string("1\r\n00:00:01,000 --> 00:00:02,000\r\n\xD6\xD0\xCE\xC4\r\n");
    threw = false;
    try {
        out = jellyfin::SafeDumpJson(subtitle);
    } catch (const std::exception &) {
        threw = true;
    }
    Expect(!threw, "GBK 编码的字幕文本不抛异常（否则「取到字幕」会变成「操作失败」）");
    Expect(out.find("00:00:01,000") != std::string::npos,
           "合法部分（时间轴）完整保留，只替换非法字节");
}

/**
 * 与 nlohmann `value()` 的差异对照 —— 这就是本文件存在的理由。
 *
 * 断言"同一个输入，`value()` 会抛而 json_arg::Int 不会"。若哪天 nlohmann 改了
 * `value()` 的语义（不再抛），这条用例会失败，提示我们可以简化实现。
 */
void TestDocumentsDifferenceFromValue()
{
    const nlohmann::json nullField = Parse(R"({"k":null})");
    bool valueThrew = false;
    try {
        (void)nullField.value("k", 0LL);
    } catch (const std::exception &) {
        valueThrew = true;
    }
    Expect(valueThrew, "对照组：nlohmann::value() 对 null 字段确实会抛（本文件因此存在）");
    Expect(Int(nullField, "k", 0) == 0, "json_arg::Int 对同一输入安全返回 fallback");
}

} // namespace

int main()
{
    std::cout << "== json_arg 主机单测 ==\n";
    TestNeverThrowsOnMismatchedTypes();
    TestStringSemantics();
    TestIntSemantics();
    TestObjectSemantics();
    TestInt32DoesNotWrapAround();
    TestSafeDumpToleratesInvalidUtf8();
    TestBoolSemantics();
    TestDocumentsDifferenceFromValue();

    if (gFailures == 0) {
        std::cout << "All json_arg tests passed\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed\n";
    return 1;
}
