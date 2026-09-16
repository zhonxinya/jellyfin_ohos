#include "media_api.h"

#include <sstream>

namespace jellyfin {
namespace api {
namespace {

std::string EncodeQuery(const std::string &value)
{
    static const char *kHex = "0123456789ABCDEF";
    std::string out;
    out.reserve(value.size() * 3);
    for (unsigned char c : value) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' ||
            c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else if (c == ' ') {
            out.push_back('+');
        } else {
            out.push_back('%');
            out.push_back(kHex[c >> 4]);
            out.push_back(kHex[c & 0x0F]);
        }
    }
    return out;
}

const char *kDefaultItemFields =
    "BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,Status,EndDate,UserData,CollectionType";

} // namespace

ApiResult queryItems(JellyfinApiClient &client, const std::string &userId, const ItemsQuery &query)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQuery(userId) << "/Items?"
         << "Recursive=" << (query.recursive ? "true" : "false") << "&Fields="
         << EncodeQuery(query.fields.empty() ? kDefaultItemFields : query.fields)
         << "&EnableUserData=" << (query.enableUserData ? "true" : "false")
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&StartIndex=" << query.startIndex << "&Limit=" << query.limit;
    if (!query.parentId.empty()) {
        path << "&ParentId=" << EncodeQuery(query.parentId);
    }
    if (!query.searchTerm.empty()) {
        path << "&SearchTerm=" << EncodeQuery(query.searchTerm);
    }
    if (!query.includeItemTypes.empty()) {
        path << "&IncludeItemTypes=" << EncodeQuery(query.includeItemTypes);
    } else if (query.searchTerm.empty() && query.personIds.empty()) {
        path << "&IncludeItemTypes=Movie,Series,Episode,Audio,MusicAlbum,Folder,BoxSet";
    }
    if (!query.sortBy.empty()) {
        path << "&SortBy=" << EncodeQuery(query.sortBy);
    }
    if (!query.sortOrder.empty()) {
        path << "&SortOrder=" << EncodeQuery(query.sortOrder);
    }
    if (query.favoriteOnly) {
        path << "&Filters=IsFavorite";
    }
    if (!query.genreIds.empty()) {
        path << "&GenreIds=" << EncodeQuery(query.genreIds);
    }
    if (!query.studioIds.empty()) {
        path << "&StudioIds=" << EncodeQuery(query.studioIds);
    }
    if (!query.personIds.empty()) {
        path << "&PersonIds=" << EncodeQuery(query.personIds);
    }
    if (!query.mediaTypes.empty()) {
        path << "&MediaTypes=" << EncodeQuery(query.mediaTypes);
    }
    if (!query.excludeItemTypes.empty()) {
        path << "&ExcludeItemTypes=" << EncodeQuery(query.excludeItemTypes);
    }
    return client.getJson(path.str());
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
    path << "/Users/" << EncodeQuery(userId) << "/Items/Resume?"
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
    path << "/Users/" << EncodeQuery(userId) << "/Items/Latest?Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&IncludeItemTypes=Movie,Series,Episode";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQuery(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getNextUp(JellyfinApiClient &client, const std::string &userId, int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Shows/NextUp?UserId=" << EncodeQuery(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData,SeriesName,IndexNumber"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    return client.getJson(path.str());
}

ApiResult getGenres(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                    int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Genres?UserId=" << EncodeQuery(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQuery(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getStudios(JellyfinApiClient &client, const std::string &userId, const std::string &parentId,
                     int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Studios?UserId=" << EncodeQuery(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQuery(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getSuggestions(JellyfinApiClient &client, const std::string &userId,
                         const std::string &parentId, int limit)
{
    std::ostringstream path;
    path << "/Items/Suggestions?UserId=" << EncodeQuery(userId) << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    if (!parentId.empty()) {
        path << "&ParentId=" << EncodeQuery(parentId);
    }
    return client.getJson(path.str());
}

ApiResult getUpcomingEpisodes(JellyfinApiClient &client, const std::string &userId, int startIndex,
                              int limit)
{
    std::ostringstream path;
    path << "/Shows/Upcoming?UserId=" << EncodeQuery(userId) << "&StartIndex=" << startIndex
         << "&Limit=" << limit
         << "&Fields=BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,UserData,SeriesName,IndexNumber"
         << "&EnableImageTypes=Primary,Backdrop,Thumb";
    return client.getJson(path.str());
}

ApiResult getItem(JellyfinApiClient &client, const std::string &userId, const std::string &itemId)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQuery(userId) << "/Items/" << EncodeQuery(itemId)
         << "?Fields=Overview,Genres,People,MediaSources,Path,PrimaryImageAspectRatio,"
            "ChildCount,RecursiveItemCount,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,"
            "CommunityRating,OfficialRating,ProductionYear,RunTimeTicks,UserData,ImageTags,"
            "BackdropImageTags,Taglines,CollectionType";
    return client.getJson(path.str());
}

ApiResult getSeasons(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId)
{
    std::ostringstream path;
    path << "/Shows/" << EncodeQuery(seriesId) << "/Seasons?userId=" << EncodeQuery(userId)
         << "&Fields=PrimaryImageAspectRatio,BasicSyncInfo"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

ApiResult getEpisodes(JellyfinApiClient &client, const std::string &userId, const std::string &seriesId,
                      const std::string &seasonId)
{
    std::ostringstream path;
    path << "/Shows/" << EncodeQuery(seriesId) << "/Episodes?userId=" << EncodeQuery(userId)
         << "&SeasonId=" << EncodeQuery(seasonId)
         << "&Fields=Overview,PrimaryImageAspectRatio,RunTimeTicks,IndexNumber,UserData"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

ApiResult getSimilar(JellyfinApiClient &client, const std::string &userId, const std::string &itemId,
                     int limit)
{
    std::ostringstream path;
    path << "/Items/" << EncodeQuery(itemId) << "/Similar?userId=" << EncodeQuery(userId)
         << "&Limit=" << limit
         << "&Fields=PrimaryImageAspectRatio,ProductionYear,UserData"
         << "&EnableImageTypes=Primary";
    return client.getJson(path.str());
}

} // namespace api
} // namespace jellyfin
