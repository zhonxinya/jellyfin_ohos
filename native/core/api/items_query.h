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
};

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
