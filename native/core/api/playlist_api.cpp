#include "playlist_api.h"

#include "url_util.h"

#include <sstream>

namespace jellyfin {
namespace api {

ApiResult createPlaylist(JellyfinApiClient &client, const std::string &userId,
                         const std::string &name, const std::string &itemId,
                         const std::string &mediaType)
{
    nlohmann::json body = {
        {"Name", name},
        {"Ids", nlohmann::json::array({itemId})},
        {"UserId", userId},
        {"MediaType", mediaType.empty() ? std::string("Video") : mediaType},
    };
    return client.postJson("/Playlists", body);
}

ApiResult addToPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                        const std::string &userId, const std::string &itemId)
{
    // id 必须编码：条目 id 目前都是十六进制串，但按约定不能假设它永远不含保留字符
    // （原来直接拼进 query string，一旦出现 '&' 就会把请求拆坏）
    std::ostringstream path;
    path << "/Playlists/" << EncodeQueryComponent(playlistId) << "/Items?Ids="
         << EncodeQueryComponent(itemId) << "&userId=" << EncodeQueryComponent(userId);
    return client.postJson(path.str(), nullptr);
}

ApiResult getPlaylists(JellyfinApiClient &client, const std::string &userId,
                       int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Users/" << EncodeQueryComponent(userId)
         << "/Items?IncludeItemTypes=Playlist&Recursive=true"
         << "&StartIndex=" << startIndex << "&Limit=" << limit
         << "&EnableTotalRecordCount=true"
         // ChildCount 用于列表页显示"共 N 首/部"；MediaType 用于区分视频列表与音乐列表
         << "&Fields=ChildCount,MediaType,PrimaryImageAspectRatio";
    return client.getJson(path.str());
}

ApiResult getPlaylistItems(JellyfinApiClient &client, const std::string &playlistId,
                           const std::string &userId, int startIndex, int limit)
{
    std::ostringstream path;
    path << "/Playlists/" << EncodeQueryComponent(playlistId) << "/Items?"
         // userId 必填：实测缺省时该端点在 10.8.12 上返回 400
         << "userId=" << EncodeQueryComponent(userId)
         << "&StartIndex=" << startIndex << "&Limit=" << limit
         // PlaylistItemId 是"列表条目 id"，移除/排序要用它；UserData 供观看状态角标
         << "&Fields=PlaylistItemId,PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,UserData,"
            "MediaSources"
         << "&EnableImageTypes=Primary,Backdrop,Thumb"
         << "&EnableTotalRecordCount=true";
    return client.getJson(path.str());
}

ApiResult removeFromPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                             const std::string &entryIds)
{
    std::ostringstream path;
    path << "/Playlists/" << EncodeQueryComponent(playlistId) << "/Items?entryIds="
         << EncodeQueryComponent(entryIds);
    return client.deleteJson(path.str());
}

ApiResult movePlaylistItem(JellyfinApiClient &client, const std::string &playlistId,
                           const std::string &entryId, int newIndex)
{
    if (newIndex < 0) {
        return ApiResult{};
    }
    std::ostringstream path;
    path << "/Playlists/" << EncodeQueryComponent(playlistId) << "/Items/"
         << EncodeQueryComponent(entryId) << "/Move/" << newIndex;
    return client.postJson(path.str(), nullptr);
}

ApiResult deletePlaylist(JellyfinApiClient &client, const std::string &playlistId)
{
    return client.deleteJson("/Items/" + EncodeQueryComponent(playlistId));
}

} // namespace api
} // namespace jellyfin
