/**
 * Host-side unit tests for text_util.h 的 UTF-8 容错（IsValidUtf8 / SanitizeUtf8）。
 *
 * 守的是一条硬约束：**解析服务端响应体之前，非法 UTF-8 必须被收敛掉**。
 *
 * 为什么值得单测：nlohmann 的 `json::parse()` 对非法 UTF-8 是抛异常（本机实测 3.11.3：
 * GBK 字节抛 `parse_error.101`），而 `dump()` 才有的 `error_handler_t::replace` 对 parse
 * 不适用 —— **parse 没有容错档位**。服务端文本里出现非法 UTF-8 是真实场景（音乐库里的
 * GBK 标签、GBK 字幕文件、截断在多字节中间的响应），一旦在 `interpret()` 里抛出，
 * 整份响应就退化成 "JSON parse error"：**一个曲目名字乱码，整个音乐库都打不开**。
 *
 * 所以这里既断言"非法字节被替换成 U+FFFD"，也断言"清洗后的 JSON 确实能解析出来"。
 *
 * Build (from repo root):
 *   g++ -std=c++17 -I native/core -I native/third_party -I native/third_party/nlohmann \
 *       native/core/tests/test_text_repair.cpp -o test_text_repair
 */

#include "json_dump.h"
#include "text_util.h"

#include <iostream>
#include <string>

using jellyfin::IsValidUtf8;
using jellyfin::SanitizeUtf8;

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

/** 统计 U+FFFD（EF BF BD）出现次数 —— 用来钉住"每个非法字节换一个替换字符" */
std::size_t CountReplacementChars(const std::string &text)
{
    std::size_t count = 0;
    for (std::size_t pos = 0; pos + 2 < text.size();) {
        if (static_cast<unsigned char>(text[pos]) == 0xEFu &&
            static_cast<unsigned char>(text[pos + 1]) == 0xBFu &&
            static_cast<unsigned char>(text[pos + 2]) == 0xBDu) {
            ++count;
            pos += 3;
        } else {
            ++pos;
        }
    }
    return count;
}

void TestValidUtf8()
{
    Expect(IsValidUtf8(""), "空串合法");
    Expect(IsValidUtf8("Movie 2001"), "纯 ASCII 合法");
    Expect(IsValidUtf8("流浪地球2"), "中文合法");
    Expect(IsValidUtf8(std::string("\xF0\x9F\x8E\xB5")), "四字节 emoji（U+1F3B5）合法");
    Expect(IsValidUtf8(std::string("\xE4\xB8\xAD")), "三字节 中（U+4E2D）合法");
    Expect(IsValidUtf8(std::string("\xC2\xA9")), "两字节 ©（U+00A9）合法");
}

void TestInvalidUtf8()
{
    // 截断在多字节序列中间：服务端响应被切、或 GBK 标签被当成 UTF-8
    Expect(!IsValidUtf8(std::string("Movie \xE4\xB8")), "截断的三字节序列非法");
    Expect(!IsValidUtf8(std::string("\xE4")), "孤立的 lead 字节非法");
    // 孤立续字节：GBK 里大量出现（GBK 字节落在 0x80..0xBF 区间时）
    Expect(!IsValidUtf8(std::string("\x80\x80")), "孤立续字节非法");
    Expect(!IsValidUtf8(std::string("测试\x80")), "合法中文后跟续字节非法");
    // GBK「测试」= B2 E2 CA D4：这串字节在 UTF-8 里非法（B2/CA/D4 都是续字节位置）
    Expect(!IsValidUtf8(std::string("\xB2\xE2\xCA\xD4")), "GBK 字节非法");
    // 过长编码 / 代理区 / 超范围：标准解析器一律拒绝
    Expect(!IsValidUtf8(std::string("\xC0\xAF")), "过长编码 C0 AF 非法");
    Expect(!IsValidUtf8(std::string("\xE0\x80\xAF")), "过长编码 E0 80 AF 非法");
    Expect(!IsValidUtf8(std::string("\xED\xA0\x80")), "代理区 U+D800 非法");
    Expect(!IsValidUtf8(std::string("\xF4\x90\x80\x80")), "超出 U+10FFFF 非法");
    Expect(!IsValidUtf8(std::string("\xC2\x41")), "lead 后跟非续字节非法");
}

void TestSanitizeUtf8()
{
    // 合法文本必须原样返回（不能"顺手规范化"）
    const std::string chinese = "流浪地球2 主题曲";
    Expect(SanitizeUtf8(chinese) == chinese, "合法中文原样返回");

    // 非法字节 → U+FFFD；其余字节必须完整保留（中文不能被切坏）
    const std::string truncated = std::string("Movie \xE4\xB8");
    const std::string fixed = SanitizeUtf8(truncated);
    Expect(IsValidUtf8(fixed), "清洗后是合法 UTF-8");
    Expect(fixed.compare(0, 6, "Movie ") == 0, "清洗保留前面的 ASCII");
    Expect(CountReplacementChars(fixed) == 2, "两个非法字节 → 两个 U+FFFD",
           "got " + std::to_string(CountReplacementChars(fixed)));

    const std::string stray = std::string("\x80\x80");
    Expect(CountReplacementChars(SanitizeUtf8(stray)) == 2, "孤立续字节逐个替换");

    // GBK 名字：清洗后中文部分整体保留，只有非法字节变成 �
    const std::string mixed = std::string("专辑 ") + "\xB2\xE2\xCA\xD4" + " 曲目";
    const std::string mixedFixed = SanitizeUtf8(mixed);
    Expect(IsValidUtf8(mixedFixed), "GBK 混排清洗后合法");
    Expect(mixedFixed.compare(0, 7, "专辑 ") == 0, "GBK 混排保留前置中文");
    Expect(CountReplacementChars(mixedFixed) == 4, "GBK 四个字节 → 四个 U+FFFD");
}

/**
 * 核心回归（这条才是这个文件存在的理由）：
 * 非法 UTF-8 的响应体在裸 `parse()` 上会抛，清洗后必须能解析出来 ——
 * 也就是"一个名字乱码"不该升级成"整个列表打不开"。
 */
void TestJsonBodyWithGbkName()
{
    // 用真实 GBK 字节构造 JSON：服务端把 GBK 标签原样吐出来时的样子
    std::string body = "{\"Items\":[{\"Name\":\"";
    body += "\xB2\xE2\xCA\xD4"; // GBK「测试」
    body += "\",\"Id\":\"abc\"}]}";

    bool rawThrew = false;
    try {
        const nlohmann::json ignored = nlohmann::json::parse(body);
        (void)ignored;
    } catch (const std::exception &) {
        rawThrew = true;
    }
    Expect(rawThrew, "裸 parse() 对 GBK 字节确实会抛（这就是要修的场景）");

    bool sanitizedThrew = false;
    std::string name;
    try {
        const nlohmann::json j = nlohmann::json::parse(SanitizeUtf8(body));
        name = j["Items"][0]["Name"].get<std::string>();
        // 其余字段必须完好：清洗不能把整份响应毁掉
        Expect(j["Items"][0]["Id"].get<std::string>() == "abc", "清洗后其余字段完好");
    } catch (const std::exception &) {
        sanitizedThrew = true;
    }
    Expect(!sanitizedThrew, "清洗后 parse() 不再抛");
    Expect(!name.empty(), "清洗后名字字段仍可读出");
    Expect(CountReplacementChars(name) == 4, "名字里的 GBK 字节显示为 4 个 U+FFFD");

    // 清洗后的结果必须能安全写回 ArkTS（dump 不得再抛）
    bool dumpThrew = false;
    std::string dumped;
    try {
        dumped = jellyfin::SafeDumpJson(nlohmann::json::parse(SanitizeUtf8(body)));
    } catch (const std::exception &) {
        dumpThrew = true;
    }
    Expect(!dumpThrew, "清洗后的响应可以安全 dump 给 ArkTS");
    Expect(!dumped.empty(), "dump 结果非空");
}

} // namespace

int main()
{
    TestValidUtf8();
    TestInvalidUtf8();
    TestSanitizeUtf8();
    TestJsonBodyWithGbkName();

    if (gFailures == 0) {
        std::cout << "\nAll text_repair assertions passed.\n";
        return 0;
    }
    std::cerr << "\n" << gFailures << " assertion(s) failed.\n";
    return 1;
}
