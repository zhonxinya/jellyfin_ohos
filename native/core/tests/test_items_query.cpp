/**
 * `/Users/{userId}/Items` 查询路径构造的主机侧单测。
 *
 * 为什么值得单测：媒体库的筛选/排序/分页最后都落到这一串 query string 上，
 * 拼错一个参数名不会报错、只会"静默地不生效"（服务端忽略未知参数），
 * 因此在主机上断言参数是否真的进了 URL，是这类缺陷最便宜的拦截方式。
 */
#include "api/items_query.h"

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

void ExpectNoParam(const std::string &path, const std::string &name, const std::string &what)
{
    if (path.find(name + "=") != std::string::npos) {
        std::printf("  [FAIL] %s（不该出现参数 %s）\n        实际: %s\n", what.c_str(), name.c_str(),
                    path.c_str());
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

void TestFieldsOverride()
{
    std::printf("自定义 Fields / 自定义 userId 转义\n");
    jellyfin::api::ItemsQuery query = BaseQuery();
    query.fields = "UserData,Overview";
    query.enableUserData = false;
    const std::string path = jellyfin::api::BuildItemsQueryPath("u", query);
    ExpectParam(path, "Fields", "UserData,Overview", "自定义 Fields 覆盖默认字段集");
    ExpectContains(path, "EnableUserData=false", "可关闭用户数据");

    const std::string escaped = jellyfin::api::BuildItemsQueryPath("u ser/1", BaseQuery());
    ExpectTrue(escaped.find("/Users/u+ser%2F1/Items?") != std::string::npos,
               "userId 中的空格与斜杠被转义（不会破坏路径结构）");
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
    TestFieldsOverride();
    if (g_failures != 0) {
        std::printf("== 失败 %d 项 ==\n", g_failures);
        return 1;
    }
    std::printf("== 全部通过 ==\n");
    return 0;
}
