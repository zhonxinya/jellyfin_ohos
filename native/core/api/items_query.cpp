#include "items_query.h"

#include "url_util.h"

#include <sstream>

namespace jellyfin {
namespace api {
namespace {

/**
 * 未指定 Fields 时请求的字段集。
 *
 * `UserData` 是观看状态与播放进度的来源（卡片上的"已看"角标与进度条都靠它），
 * `ProductionYear/CollectionType` 供卡片的元信息行与跳转判断使用。
 */
const char *kDefaultItemFields =
    "BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,Status,EndDate,UserData,CollectionType";

} // namespace

std::string BuildItemsQueryPath(const std::string &userId, const ItemsQuery &query)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId) << "/Items?"
         << "Recursive=" << (query.recursive ? "true" : "false") << "&Fields="
         << EncodeQueryComponent(query.fields.empty() ? kDefaultItemFields : query.fields)
         << "&EnableUserData=" << (query.enableUserData ? "true" : "false")
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&EnableTotalRecordCount=" << (query.enableTotalRecordCount ? "true" : "false")
         << "&StartIndex=" << query.startIndex << "&Limit=" << query.limit;
    if (!query.parentId.empty()) {
        path << "&ParentId=" << EncodeQueryComponent(query.parentId);
    }
    if (!query.searchTerm.empty()) {
        path << "&SearchTerm=" << EncodeQueryComponent(query.searchTerm);
    }
    if (!query.includeItemTypes.empty()) {
        path << "&IncludeItemTypes=" << EncodeQueryComponent(query.includeItemTypes);
    } else if (query.searchTerm.empty() && query.personIds.empty()) {
        // 既没指定类型、也没有搜索词/演员时，给出"媒体库里该看到的东西"的默认集合。
        //
        // 原来的集合少了 `Video` 等类型，导致 collectionType 为 homevideos 的库
        // （家庭视频，条目类型是 Video）打开后永远是空的 —— 补上 Video/Season/
        // MusicVideo/Trailer；照片（Photo/PhotoAlbum）仍不列入视频浏览的默认集合，
        // 那种库需要专门的图片浏览界面。
        path << "&IncludeItemTypes=Movie,Series,Episode,Video,Season,MusicVideo,Trailer,Audio,"
                "MusicAlbum,Folder,BoxSet";
    }
    if (!query.sortBy.empty()) {
        path << "&SortBy=" << EncodeQueryComponent(query.sortBy);
    }
    if (!query.sortOrder.empty()) {
        path << "&SortOrder=" << EncodeQueryComponent(query.sortOrder);
    }
    // Filters 是逗号分隔的集合：favoriteOnly 是它的特例，两者**叠加**而不是互相覆盖
    // （否则"收藏 + 未观看"这类组合会静默丢掉一个条件）
    std::string filters = query.filters;
    if (query.favoriteOnly) {
        if (!filters.empty()) {
            filters += ",";
        }
        filters += "IsFavorite";
    }
    if (!filters.empty()) {
        path << "&Filters=" << EncodeQueryComponent(filters);
    }
    if (!query.genreIds.empty()) {
        path << "&GenreIds=" << EncodeQueryComponent(query.genreIds);
    }
    if (!query.studioIds.empty()) {
        path << "&StudioIds=" << EncodeQueryComponent(query.studioIds);
    }
    if (!query.personIds.empty()) {
        path << "&PersonIds=" << EncodeQueryComponent(query.personIds);
    }
    if (!query.mediaTypes.empty()) {
        path << "&MediaTypes=" << EncodeQueryComponent(query.mediaTypes);
    }
    if (!query.excludeItemTypes.empty()) {
        path << "&ExcludeItemTypes=" << EncodeQueryComponent(query.excludeItemTypes);
    }
    if (!query.years.empty()) {
        path << "&Years=" << EncodeQueryComponent(query.years);
    }
    if (!query.officialRatings.empty()) {
        path << "&OfficialRatings=" << EncodeQueryComponent(query.officialRatings);
    }
    if (!query.minOfficialRating.empty()) {
        path << "&MinOfficialRating=" << EncodeQueryComponent(query.minOfficialRating);
    }
    if (!query.tags.empty()) {
        path << "&Tags=" << EncodeQueryComponent(query.tags);
    }
    if (!query.videoTypes.empty()) {
        path << "&VideoTypes=" << EncodeQueryComponent(query.videoTypes);
    }
    if (query.isHd) {
        path << "&IsHD=true";
    }
    if (query.is4k) {
        path << "&Is4K=true";
    }
    if (query.hasSubtitles) {
        path << "&HasSubtitles=true";
    }
    return path.str();
}

} // namespace api
} // namespace jellyfin
