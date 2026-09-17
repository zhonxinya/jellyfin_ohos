#include "media_api.h"

#include "url_util.h"

#include <sstream>

namespace jellyfin {
namespace api {

ApiResult queryItems(JellyfinApiClient &client, const std::string &userId, const ItemsQuery &query)
{
    return client.getJson(BuildItemsQueryPath(userId, query));
}

ApiResult getItems(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                   int startIndex, int limit, const std::string &searchTerm,
                   const std::string &includeTypes)
{
    ItemsQuery query;
    query.parentId = parentId;
    query.startIndex = startIndex;
    query.limit = limit;
    query.searchTerm = searchTerm;
    query.includeItemTypes = includeTypes;
    return queryItems(client, userId, query);
}

ApiResult getResumeItems(JellyfinApiClient &client, const std::string &userId, int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId) << "/Items/Resume?"
         << "StartIndex=" << startIndex << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&MediaTypes=Video";
    return client.getJson(path.str());
}

ApiResult getLatest(JellyfinApiClient &client, const std::string &userId, int limit,
                    const std::string &parentId)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId) << "/Items/Latest?Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&IncludeItemTypes=Movie,Series,Episode";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQueryComponent(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getNextUp(JellyfinApiClient &client, const std::string &userId, int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Shows/NextUp?UserId=" << EncodeQueryComponent(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData,SeriesName,IndexNumber"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    return client.getJson(path.str());
}

ApiResult getGenres(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                    int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Genres?UserId=" << EncodeQueryComponent(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQueryComponent(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getStudios(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                     int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Studios?UserId=" << EncodeQueryComponent(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQueryComponent(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getSuggestions(JellyfinApiClient &client, const std::string &userId,
                         const std::string &parentId, int limit)
{
    // 该路由在 Jellyfin 版本之间换过：10.8.x 用 `/Users/{userId}/Suggestions`，
    // 10.10.x 用 `/Items/Suggestions`。设备实测（服务器 10.8.12）：`/Items/Suggestions` 返回 **405**，
    // 媒体库「建议」标签因此永远为空。按"新式优先、404/405 回退"处理。
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId) << "/Suggestions?Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQueryComponent(parentId);
    }
    ApiResult result = client.getJson(path.str());
    if (!result.ok() && (result.error.statusCode == 404 || result.error.statusCode == 405)) {
        std::ostringstream legacy;
        legacy << "/Items/Suggestions?UserId=" << EncodeQueryComponent(userId) << "&Limit=" << limit
               << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
               << "&EnableImageTypes=Primary,Backdrop,Thumb";
        if (!parentId.empty()) {
            legacy << "&ParentId=" << EncodeQueryComponent(parentId);
        }
        return client.getJson(legacy.str());
    }
    return result;
}

ApiResult getUpcomingEpisodes(JellyfinApiClient &client, const std::string &userId, int startIndex,
                              int limit)
{
    std::ostringstream path;
    path << "/Shows/Upcoming?UserId=" << EncodeQueryComponent(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData,SeriesName,IndexNumber"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    return client.getJson(path.str());
}

ApiResult getItem(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId) << "/Items/" << EncodeQueryComponent(itemId)
         << "?Fields=Overview,Genres,People,MediaSources,Path,PrimaryImageAspectRatio,"
            "ChildCount,RecursiveItemCount,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,"
            "CommunityRating,OfficialRating,ProductionYear,RunTimeTicks,UserData,ImageTags,"
            "BackdropImageTags,Taglines,CollectionType";
    return client.getJson(path.str());
}

ApiResult getSeasons(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId)
{
    std::ostringstream path;
    path << "/Shows/" << EncodeQueryComponent(seriesId) << "/Seasons?userId=" << EncodeQueryComponent(userId)
         << "&Fields=PrimaryImageAspectRatio,BasicSyncInfo"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

ApiResult getEpisodes(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId,
                      const std::string &seasonId)
{
    std::ostringstream path;
    path << "/Shows/" << EncodeQueryComponent(seriesId) << "/Episodes?userId=" << EncodeQueryComponent(userId)
         << "&SeasonId=" << EncodeQueryComponent(seasonId)
         << "&Fields=Overview,PrimaryImageAspectRatio,RunTimeTicks,IndexNumber,UserData"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

ApiResult getSimilar(JellyfinApiClient &client, const std::string &userId, const std::string &itemId,
                     int limit)
{
    std::ostringstream path;
    path << "/Items/" << EncodeQueryComponent(itemId) << "/Similar?userId=" << EncodeQueryComponent(userId)
         << "&Limit=" << limit
         << "&Fields=PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

} // namespace api
} // namespace jellyfin
