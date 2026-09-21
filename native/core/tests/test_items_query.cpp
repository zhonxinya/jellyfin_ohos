/**
 * `/Users/{userId}/Items` 查询路径构造的主机侧单测。
 *
 * 为什么值得单测：媒体库的筛选/排序/分页最后都落到这一串 query string 上，
 * 拼错一个参数名不会报错、只会"静默地不生效"（服务端忽略未知参数），
 * 因此在主机上断言参数是否真的进了 URL，是这类缺陷最便宜的拦截方式。
 *
 * 第二个被覆盖的对象是 `ParseItemsQueryJson()` / `ParsePlaybackOptionsJson()`
 * （宿主 JSON → API 结构体）。它们以前在 NAPI 层用 `j.value(key, default)` 逐字段读：
 * `value()` **只在键不存在时**返回默认值，键存在但类型不符（尤其 ArkTS 经
 * `JSON.stringify` 原样带下来的 `null`）会抛 `type_error.302`，而它们跑在 UI 线程的
 * 同步路径上 —— 异常逸出即进程终止。下移到 core 后就能在这里断言
 * "任何畸形输入都不抛、且回落到默认值"。
 */
#include "api/items_query.h"
#include "api/options_parse.h"

#include <cstdio>
#include <string>

namespace {

int g_failures = 0;

void ExpectTrue(bool cond, const std::string &what)
{
    if (!cond) {
        std::printf("  [FAIL] %s\n", what.c_str());
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

void ExpectContains(const std::string &haystack, const std::string &needle,
                    const std::string &what)
{
    const bool found = haystack.find(needle) != std::string::npos;
    if (!found) {
        std::printf("  [FAIL] %s\n        缺少: %s\n        实际: %s\n", what.c_str(), needle.c_str(),
                    haystack.c_str());
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

/** 百分号解码（`+` 还原为空格），用于按"参数语义值"断言而不是按编码后的字面量断言 */
std::string Decode(const std::string &value)
{
    std::string out;
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '+') {
            out.push_back(' ');
        } else if (value[i] == '%' && i + 2 < value.size()) {
            const std::string hex = value.substr(i + 1, 2);
            out.push_back(static_cast<char>(std::strtol(hex.c_str(), nullptr, 16)));
            i += 2;
        } else {
            out.push_back(value[i]);
        }
    }
    return out;
}

/** 取查询参数值（已解码）；不存在时返回空串 */
std::string Param(const std::string &path, const std::string &name)
{
    const std::string key = name + "=";
    const size_t at = path.find(key);
    if (at == std::string::npos) {
        return {};
    }
    const size_t begin = at + key.size();
    const size_t end = path.find('&', begin);
    return Decode(path.substr(begin, end == std::string::npos ? std::string::npos : end - begin));
}

/**
 * 断言某个查询参数的**语义值**。
 *
 * 为什么不直接断言 `Years=2019,2020` 这样的字面量：逗号、中文等都会被百分号编码
 * （`Years=2019%2C2020`），服务端解码后完全等价（设备实测 `%2C` 与 `,` 结果一致）。
 * 按解码后的值断言，既能覆盖真实契约，又不会把编码实现细节写死进测试。
 */
void ExpectParam(const std::string &path, const std::string &name, const std::string &want,
                 const std::string &what)
{
    const std::string got = Param(path, name);
    if (got != want) {
        std::printf("  [FAIL] %s\n        参数 %s: 实际=[%s] 期望=[%s]\n", what.c_str(), name.c_str(),
                    got.c_str(), want.c_str());
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

void ExpectNotContains(const std::string &haystack, const std::string &needle,
                       const std::string &what)
{
    const bool found = haystack.find(needle) != std::string::npos;
    if (found) {
        std::printf("  [FAIL] %s\n        不该出现: %s\n        实际: %s\n", what.c_str(),
                    needle.c_str(), haystack.c_str());
        ++g_failures;
    } else {
        std::printf("  [ ok ] %s\n", what.c_str());
    }
}

jellyfin::api::ItemsQuery BaseQuery()
{
    jellyfin::api::ItemsQuery query;
    query.parentId = "lib-1";
    query.startIndex = 40;
    query.limit = 40;
    return query;
}

void TestDefaults()
{
    std::printf("默认查询\n");
    const std::string path = jellyfin::api::BuildItemsQueryPath("user-1", BaseQuery());
    ExpectContains(path, "/Users/user-1/Items?", "路径前缀带 userId");
    ExpectContains(path, "Recursive=true", "默认递归");
    ExpectContains(path, "StartIndex=40", "起始下标");
    ExpectContains(path, "Limit=40", "每页条数");
    ExpectContains(path, "ParentId=lib-1", "父级（媒体库）");
    ExpectContains(path, "EnableUserData=true", "请求用户数据（观看状态/进度）");
    ExpectContains(path, "EnableTotalRecordCount=true", "请求总数（界面要显示共 N 项）");
    ExpectParam(path, "IncludeItemTypes",
                "Movie,Series,Episode,Video,Season,MusicVideo,Trailer,Audio,MusicAlbum,Folder,BoxSet",
                "未指定类型时给默认类型集合（含 Video，否则家庭视频库永远为空）");
    ExpectNotContains(path, "Filters=", "没有筛选条件时不带 Filters");
}

void TestSearchAndTypes()
{
    std::printf("搜索 / 类型 / 排除类型\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.searchTerm = "阴阳路4";
    query.includeItemTypes = "Movie";
    query.excludeItemTypes = "BoxSet";
    query.personIds = "person-9";
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    // 中文按 UTF-8 逐字节百分号编码
    ExpectContains(path, "SearchTerm=%E9%98%B4%E9%98%B3%E8%B7%AF4", "中文搜索词按 UTF-8 百分号编码");
    ExpectContains(path, "IncludeItemTypes=Movie", "显式类型优先于默认类型集合");
    ExpectNotContains(path, "IncludeItemTypes=Movie,Series", "显式类型时不追加默认集合");
    ExpectContains(path, "ExcludeItemTypes=BoxSet", "排除类型");
    ExpectContains(path, "PersonIds=person-9", "按演员筛选");
}

void TestFavoriteFlagMergesWithFilters()
{
    std::printf("收藏开关与 Filters 叠加\n");
    jellyfin::api::ItemsQuery onlyFavorite = BaseQuery();
    onlyFavorite.favoriteOnly = true;
    ExpectContains(jellyfin::api::BuildItemsQueryPath("u", onlyFavorite), "Filters=IsFavorite",
                   "只勾选收藏 → Filters=IsFavorite");

    jellyfin::api::ItemsQuery merged = BaseQuery();
    merged.favoriteOnly = true;
    merged.filters = "IsUnplayed";
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", merged);
    ExpectParam(path, "Filters", "IsUnplayed,IsFavorite", "收藏 + 未观看两个条件都要保留");
    ExpectContains(path, "Filters=", "Filters 参数存在");
    // 关键回归点：旧实现里 favoriteOnly 会覆盖 filters（或反之），组合条件被悄悄丢掉
    ExpectTrue(path.find("Filters=IsFavorite") == std::string::npos,
               "不再是孤立的 Filters=IsFavorite（两个条件已合并）");
}

void TestPlaybackStateFilters()
{
    std::printf("播放状态筛选\n");
    const char *cases[] = {"IsUnplayed", "IsPlayed", "IsResumable"};
    for (const char *value : cases) {
        jellyfin::api::ItemsQuery query = BaseQuery();
        query.filters = value;
        ExpectContains(jellyfin::api::BuildItemsQueryPath("u", query),
                       std::string("Filters=") + value,
                       std::string("状态筛选 ") + value + " 进入 URL");
    }
}

void TestFacetFilters()
{
    std::printf("年份 / 分级 / 标签 / 介质\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.years = "2019,2020";
    query.officialRatings = "PG-13,TV-MA";
    query.minOfficialRating = "PG";
    query.tags = "科幻";
    query.videoTypes = "BluRay";
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    ExpectParam(path, "Years", "2019,2020", "年份（多值逗号分隔）");
    ExpectParam(path, "OfficialRatings", "PG-13,TV-MA", "官方分级");
    ExpectContains(path, "MinOfficialRating=PG", "最低官方分级");
    ExpectContains(path, "Tags=%E7%A7%91%E5%B9%BB", "标签（中文编码）");
    ExpectContains(path, "VideoTypes=BluRay", "视频介质类型");
    ExpectNotContains(path, "IsHD=", "未勾选时不带 IsHD");
    ExpectNotContains(path, "Is4K=", "未勾选时不带 Is4K");
    ExpectNotContains(path, "HasSubtitles=", "未勾选时不带 HasSubtitles");
}

void TestBooleanSwitches()
{
    std::printf("分辨率 / 字幕开关\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.isHd = true;
    query.is4k = true;
    query.hasSubtitles = true;
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    ExpectContains(path, "IsHD=true", "只要高清");
    ExpectContains(path, "Is4K=true", "只要 4K");
    ExpectContains(path, "HasSubtitles=true", "只要带字幕");
}

void TestSortAndPaging()
{
    std::printf("排序 / 分页 / 总数开关\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.sortBy = "PremiereDate,SortName";
    query.sortOrder = "Descending";
    query.recursive = false;
    query.enableTotalRecordCount = false;
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    ExpectParam(path, "SortBy", "PremiereDate,SortName", "多字段排序");
    ExpectContains(path, "SortOrder=Descending", "排序方向");
    ExpectContains(path, "Recursive=false", "非递归");
    ExpectContains(path, "EnableTotalRecordCount=false", "可关闭总数统计");
}

/**
 * `SortBy=Random` 的绕行：不能让 `Random` 进 query string。
 *
 * 背景（设备实测 + 服务端源码）：Jellyfin 10.8 的 `RandomComparer.Compare()` 是
 * `Guid.NewGuid().CompareTo(Guid.NewGuid())` —— 同一个元素跟自己比较都可能不相等，
 * 属于**不自洽的比较器**。.NET 的 `ArraySortHelper` 发现后会抛
 * `ArgumentException: Unable to sort because the IComparer.Compare() method returns
 * inconsistent results`，服务端把它变成 **HTTP 400**。实测约 8% 的请求命中，
 * 首页推荐因此"偶尔整个消失"。
 *
 * 这里断言的是"退路"：只要 `randomSamplePoolSize > 0`，请求里就**绝不能**出现
 * `SortBy=Random`，而是换成稳定排序（本地再抽样）。
 */
void TestRandomSortAvoidedWhenLocalSampling()
{
    std::printf("Random 排序：本地抽样时不下发给服务端\n");

    jellyfin::api::ItemsQuery sampled = BaseQuery();
    sampled.sortBy = "Random";
    sampled.limit = 6;
    sampled.randomSamplePoolSize = 60;
    const std::string sampledPath = jellyfin::api::BuildItemsQueryPath("u", sampled);
    ExpectTrue(sampledPath.find("Random") == std::string::npos,
               "本地抽样时 query 里不含 Random（服务端比较器不自洽会抛 400）");
    ExpectParam(sampledPath, "SortBy", "SortName", "改用稳定排序取候选池");
    ExpectParam(sampledPath, "Limit", "60",
                "Limit 换成抽样池大小（抽样后才是调用方要的 6 条）");
    ExpectTrue(jellyfin::api::UsesLocalRandomSample(sampled),
               "UsesLocalRandomSample 与 BuildItemsQueryPath 判断一致（走抽样）");

    // 关闭本地抽样时保持原行为（显式传 Random 的调用方自己负责）
    jellyfin::api::ItemsQuery native = BaseQuery();
    native.sortBy = "Random";
    native.limit = 6;
    native.randomSamplePoolSize = 0;
    const std::string nativePath = jellyfin::api::BuildItemsQueryPath("u", native);
    ExpectParam(nativePath, "SortBy", "Random", "未启用本地抽样时仍可按要求下发给服务端");
    ExpectParam(nativePath, "Limit", "6", "未启用本地抽样时 Limit 就是调用方要的条数");
    ExpectTrue(!jellyfin::api::UsesLocalRandomSample(native), "未启用本地抽样时不走抽样分支");

    // 非 Random 排序不受影响，且仍带排序方向
    jellyfin::api::ItemsQuery normal = BaseQuery();
    normal.sortBy = "SortName";
    normal.sortOrder = "Descending";
    normal.limit = 6;
    normal.randomSamplePoolSize = 60;
    const std::string normalPath = jellyfin::api::BuildItemsQueryPath("u", normal);
    ExpectParam(normalPath, "SortBy", "SortName", "普通排序不受本地抽样影响");
    ExpectContains(normalPath, "SortOrder=Descending", "普通排序仍带排序方向");
    ExpectParam(normalPath, "Limit", "6", "普通排序的 Limit 不被抽样池改写");
    ExpectTrue(!jellyfin::api::UsesLocalRandomSample(normal),
               "排序里没有 Random 时即使开了池子也不抽样");
}

void TestFieldsOverride()
{    std::printf("自定义 Fields / 自定义 userId 转义\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.fields = "UserData,Overview";
    query.enableUserData = false;
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    ExpectParam(path, "Fields", "UserData,Overview", "自定义 Fields 覆盖默认字段集");
    ExpectContains(path, "EnableUserData=false", "可关闭用户数据");

    const std::string escaped = jellyfin::api::BuildItemsQueryPath("u ser/1", BaseQuery());
    ExpectTrue(escaped.find("/Users/u%20ser%2F1/Items?") != std::string::npos,
               "userId 中的空格与斜杠被转义（空格用 %20，见 url_util.cpp 的说明）");
}

/**
 * ParseItemsQueryJson：畸形输入绝不抛异常，且字段级回落到默认值。
 *
 * 每一条都对应一个"真会发生"的来源：`null`/类型不符来自 ArkTS 的 JSON.stringify，
 * 字符串数字来自 JS 大整数，超界来自前端误算。
 */
void TestParseItemsQueryToleratesBadInput()
{
    std::printf("ParseItemsQueryJson 容错\n");

    // 1) 非对象 / null：直接给默认查询，不抛。
    const jellyfin::api::ItemsQuery fromNull =
        jellyfin::api::ParseItemsQueryJson(nlohmann::json(nullptr));
    ExpectTrue(fromNull.limit == 50 && fromNull.recursive,
               "顶层是 null 时返回默认查询");
    const jellyfin::api::ItemsQuery fromArray =
        jellyfin::api::ParseItemsQueryJson(nlohmann::json::parse("[1,2]"));
    ExpectTrue(fromArray.limit == 50, "顶层是数组时返回默认查询");

    // 2) 关键回归：value() 会对这些输入抛 type_error.302，Parse 必须不抛。
    const auto allNull = nlohmann::json::parse(
        R"({"limit":null,"startIndex":null,"recursive":null,"parentId":null,"isHd":null})");
    const jellyfin::api::ItemsQuery fromNullFields =
        jellyfin::api::ParseItemsQueryJson(allNull);
    ExpectTrue(fromNullFields.limit == 50, "limit 为 null 回落到默认 50（不抛异常）");
    ExpectTrue(fromNullFields.startIndex == 0, "startIndex 为 null 回落到默认 0");
    ExpectTrue(fromNullFields.recursive, "recursive 为 null 回落到默认 true");
    ExpectTrue(fromNullFields.parentId.empty(), "parentId 为 null 回落到空串");
    ExpectTrue(!fromNullFields.isHd, "isHd 为 null 回落到默认 false（不能变成 true）");

    // 3) 类型不符：数字不给字符串、字符串不给数字以外的字段。
    const auto wrongTypes = nlohmann::json::parse(
        R"({"parentId":123,"limit":"60","isHd":"yes","recursive":1})");
    const jellyfin::api::ItemsQuery fromWrongTypes =
        jellyfin::api::ParseItemsQueryJson(wrongTypes);
    ExpectTrue(fromWrongTypes.parentId.empty(), "字符串字段给数字 → 回落默认（不隐式转换）");
    ExpectTrue(fromWrongTypes.limit == 60, "数字字段给纯数字字符串 → 可解析（JS 大整数场景）");
    ExpectTrue(!fromWrongTypes.isHd, "布尔字段给字符串 → 回落默认");
    ExpectTrue(fromWrongTypes.recursive, "布尔字段给数字 → 回落默认（保持严格语义）");

    // 4) 越界：unsigned 上限不能回绕成负数 limit（那会被原样拼进请求参数）。
    const auto overflow = nlohmann::json::parse(R"({"limit":18446744073709551615})");
    const jellyfin::api::ItemsQuery fromOverflow =
        jellyfin::api::ParseItemsQueryJson(overflow);
    ExpectTrue(fromOverflow.limit == 50, "limit 超出 long long → 回落默认，不回绕成负数");

    // 5) 正常路径仍然生效（容错不等于"永远返回默认值"）。
    const auto ok = nlohmann::json::parse(
        R"({"parentId":"lib-9","startIndex":80,"limit":20,"recursive":false,)"
        R"("searchTerm":"dune","isHd":true})");
    const jellyfin::api::ItemsQuery good = jellyfin::api::ParseItemsQueryJson(ok);
    ExpectTrue(good.parentId == "lib-9", "正常字段照常解析（parentId）");
    ExpectTrue(good.startIndex == 80 && good.limit == 20, "正常字段照常解析（分页）");
    ExpectTrue(!good.recursive, "正常字段照常解析（recursive=false 能生效）");
    ExpectTrue(good.searchTerm == "dune", "正常字段照常解析（searchTerm）");
    ExpectTrue(good.isHd, "正常字段照常解析（isHd=true 能生效）");

    // 6) 解析结果必须能直接喂给 BuildItemsQueryPath（两段拼接处的类型一致）。
    const std::string path = jellyfin::api::BuildItemsQueryPath("u1", good);
    ExpectContains(path, "Limit=20", "解析出的 limit 真的进了 query string");
    ExpectContains(path, "IsHD=true", "解析出的 isHd 真的进了 query string");
}

/**
 * ParsePlaybackOptionsJson：畸形输入绝不抛异常，且回落到默认播放选项。
 *
 * 这几个字段直接决定服务端是否转码、用哪条音轨，静默错值比"整页崩掉"更难查，
 * 所以既断言"不抛"，也断言"默认值语义正确"。
 */
void TestParsePlaybackOptionsToleratesBadInput()
{
    std::printf("ParsePlaybackOptionsJson 容错\n");

    const jellyfin::api::PlaybackInfoOptions fromNull =
        jellyfin::api::ParsePlaybackOptionsJson(nlohmann::json(nullptr));
    ExpectTrue(fromNull.audioStreamIndex == -1, "顶层 null → 默认音频流下标 -1");
    ExpectTrue(fromNull.enableDirectPlay && fromNull.enableDirectStream &&
                   fromNull.enableTranscoding && fromNull.includeDeviceProfile,
               "顶层 null → 三种播放方式与 DeviceProfile 均为默认开启");

    // 关键回归：这些输入会让 value() 抛 type_error.302。
    const auto allNull = nlohmann::json::parse(
        R"({"audioStreamIndex":null,"subtitleStreamIndex":null,"maxStreamingBitrate":null,)"
        R"("enableDirectPlay":null,"enableDirectStream":null,"enableTranscoding":null,)"
        R"("includeDeviceProfile":null})");
    const jellyfin::api::PlaybackInfoOptions fromNullFields =
        jellyfin::api::ParsePlaybackOptionsJson(allNull);
    ExpectTrue(fromNullFields.audioStreamIndex == -1, "audioStreamIndex 为 null → 回落 -1（不抛）");
    ExpectTrue(fromNullFields.subtitleStreamIndex == -1, "subtitleStreamIndex 为 null → 回落 -1");
    ExpectTrue(fromNullFields.maxStreamingBitrate == 0, "maxStreamingBitrate 为 null → 回落 0");
    ExpectTrue(fromNullFields.enableDirectPlay && fromNullFields.enableTranscoding,
               "布尔字段为 null → 回落 true（不能变成 false 而禁用直连）");
    ExpectTrue(fromNullFields.includeDeviceProfile,
               "includeDeviceProfile 为 null → 回落 true");

    // 类型不符
    const auto wrongTypes = nlohmann::json::parse(
        R"({"audioStreamIndex":"2","enableDirectPlay":"false","maxStreamingBitrate":8000000})");
    const jellyfin::api::PlaybackInfoOptions fromWrongTypes =
        jellyfin::api::ParsePlaybackOptionsJson(wrongTypes);
    ExpectTrue(fromWrongTypes.audioStreamIndex == 2, "数字字符串可解析（JS 传参场景）");
    ExpectTrue(fromWrongTypes.enableDirectPlay, "布尔字段给字符串 → 回落默认 true");
    ExpectTrue(fromWrongTypes.maxStreamingBitrate == 8000000, "正常数字照常解析");

    // 越界：回绕会把"很大的正数"变成 -1，即"未指定流" —— 静默改变播放语义。
    const auto overflow =
        nlohmann::json::parse(R"({"audioStreamIndex":18446744073709551615})");
    const jellyfin::api::PlaybackInfoOptions fromOverflow =
        jellyfin::api::ParsePlaybackOptionsJson(overflow);
    ExpectTrue(fromOverflow.audioStreamIndex == -1,
               "audioStreamIndex 超界 → 回落 -1（而不是回绕成碰巧合法的负值）");

    // 显式置 false 必须能生效（容错不能把用户的选择吃掉）。
    const auto off = nlohmann::json::parse(
        R"({"enableDirectPlay":false,"includeDeviceProfile":false,"subtitleStreamIndex":0})");
    const jellyfin::api::PlaybackInfoOptions explicitOff =
        jellyfin::api::ParsePlaybackOptionsJson(off);
    ExpectTrue(!explicitOff.enableDirectPlay, "显式 false 能生效（enableDirectPlay）");
    ExpectTrue(!explicitOff.includeDeviceProfile, "显式 false 能生效（includeDeviceProfile）");
    ExpectTrue(explicitOff.subtitleStreamIndex == 0,
               "下标 0 是合法值（不能与「未指定 -1」混淆）");
}

} // namespace

int main()
{
    std::printf("== BuildItemsQueryPath 单测 ==\n");
    TestDefaults();
    TestSearchAndTypes();
    TestFavoriteFlagMergesWithFilters();
    TestPlaybackStateFilters();
    TestFacetFilters();
    TestBooleanSwitches();
    TestSortAndPaging();
    TestRandomSortAvoidedWhenLocalSampling();
    TestFieldsOverride();
    TestParseItemsQueryToleratesBadInput();
    TestParsePlaybackOptionsToleratesBadInput();
    if (g_failures != 0) {
        std::printf("== 失败 %d 项 ==\n", g_failures);
        return 1;
    }
    std::printf("== 全部通过 ==\n");
    return 0;
}
