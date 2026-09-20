#ifndef JELLYFIN_CORE_API_ITEMS_QUERY_H
#define JELLYFIN_CORE_API_ITEMS_QUERY_H

#include <string>

namespace jellyfin {
namespace api {

/**
 * `/Users/{userId}/Items` 的查询条件。
 *
 * 字段与 Jellyfin 的查询参数一一对应，命名刻意保持"能看出对应哪个参数"
 * （filters → Filters、years → Years…），便于对照官方 API 文档排查。
 */
struct ItemsQuery {
    std::string parentId;
    int startIndex = 0;
    int limit = 50;
    std::string searchTerm;
    std::string includeItemTypes;
    std::string sortBy;
    std::string sortOrder;
    bool favoriteOnly = false;
    bool recursive = true;
    std::string genreIds;
    std::string studioIds;
    std::string personIds;
    std::string fields;
    std::string mediaTypes;
    std::string excludeItemTypes;
    bool enableUserData = true;
    /**
     * 观看状态等筛选（Jellyfin `Filters`，逗号分隔）。
     *
     * 取值：IsFolder / IsNotFolder / IsUnplayed / IsPlayed / IsFavorite / IsResumable /
     * Likes / Dislikes。与 `favoriteOnly` 是叠加关系（旧字段保留，避免调用方全改）。
     */
    std::string filters;
    /** 年份筛选（Jellyfin `Years`，逗号分隔，如 "2020" 或 "2019,2020"） */
    std::string years;
    /** 官方分级筛选（Jellyfin `OfficialRatings`，逗号分隔，如 "PG-13,TV-MA"） */
    std::string officialRatings;
    /** 最低官方分级（Jellyfin `MinOfficialRating`） */
    std::string minOfficialRating;
    /** 标签筛选（Jellyfin `Tags`，逗号分隔） */
    std::string tags;
    /** 视频介质类型（Jellyfin `VideoTypes`，如 BluRay/Dvd/Web） */
    std::string videoTypes;
    /** 只返回高清（Jellyfin `IsHD=true`） */
    bool isHd = false;
    /** 只返回 4K（Jellyfin `Is4K=true`） */
    bool is4k = false;
    /** 只返回带字幕的条目（Jellyfin `HasSubtitles=true`） */
    bool hasSubtitles = false;
    /**
     * 是否请求总数（Jellyfin `EnableTotalRecordCount`）。
     *
     * 为什么需要：界面要显示"共 N 项"，而 N 必须是**库里的总数**而不是"已加载条数"。
     */
    bool enableTotalRecordCount = true;
    /**
     * **本地**随机抽样池大小；0 表示关闭（走服务端原生排序）。
     *
     * 为什么需要它（这是一个**服务端缺陷的绕行**）：
     * `SortBy=Random` 会让 Jellyfin 10.8 的 `RandomComparer.Compare()` 每次比较都返回
     * `Guid.NewGuid().CompareTo(Guid.NewGuid())` —— 同一个元素与自己比较的结果都不同，
     * 是个**不自洽的比较器**。.NET 的 `ArraySortHelper` 检测到这种比较器会抛
     * `ArgumentException: Unable to sort because the IComparer.Compare() method returns
     * inconsistent results`，Kestrel 把它变成 **HTTP 400**（实测约 8% 的请求命中，
     * 响应体为空）—— 客户端侧表现为"首页推荐偶尔整个消失"。
     *
     * 服务端源码见 `docs/jellyfin-10.8.12/Emby.Server.Implementations/Sorting/RandomComparer.cs`。
     *
     * 改为本地抽样：用稳定排序（如 `SortName`）取一批候选，再在客户端随机选 `limit` 条。
     * 这样既拿到随机效果，又完全不碰服务端那个坏比较器 —— 对**任何** Jellyfin 版本都成立。
     * 见 `items_query.cpp` 的 `BuildItemsQueryPath()`。
     */
    int randomSamplePoolSize = 0;
};

/**
 * 本次查询是否走"本地随机抽样"路径。
 *
 * 两个条件缺一不可：调用方**要求**本地抽样（`randomSamplePoolSize > 0`），
 * 且排序里确实含 `Random`（否则没有随机的必要，按普通排序走即可）。
 *
 * 抽成函数是因为 `BuildItemsQueryPath()`（拼 URL）与 `queryItems()`（真正抽样）
 * 必须对"走不走这条路"给出**一致**的判断 —— 一边按抽样改 Limit、另一边没改，
 * 或者一边不下发 Random、另一边却去抽样，都会得到错误的结果集。
 */
inline bool UsesLocalRandomSample(const ItemsQuery &query)
{
    return query.randomSamplePoolSize > 0 &&
           query.sortBy.find("Random") != std::string::npos;
}

/**
 * 构造 `/Users/{userId}/Items` 查询路径（纯函数）。
 *
 * 为什么单独成函数而不是塞在 `queryItems()` 里：查询参数众多且容易拼错 ——
 * 拼错的参数名不会报错，服务端只会当没传，表现为"筛选点了没反应"。
 * 抽成不依赖网络客户端的纯函数后，主机侧单测（`native/core/tests/test_items_query.cpp`）
 * 就能在不联网、不连设备的情况下断言每个条件确实进了 query string。
 */
std::string BuildItemsQueryPath(const std::string &userId, const ItemsQuery &query);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_ITEMS_QUERY_H */
