#ifndef JELLYFIN_CORE_API_PLAYLIST_API_H
#define JELLYFIN_CORE_API_PLAYLIST_API_H

#include "api_client.h"

#include <string>

namespace jellyfin {
namespace api {

/**
 * 新建播放列表。
 *
 * `mediaType` 决定服务端把它当视频还是音频列表：原来是写死的 "Video"，
 * 于是音乐曲目也能塞进去但列表类型不对（服务端按 MediaType 分区展示）。
 */
ApiResult createPlaylist(JellyfinApiClient &client, const std::string &userId,
                         const std::string &name, const std::string &itemId,
                         const std::string &mediaType = "Video");

/** 往播放列表追加条目（`itemId` 是媒体条目 id，不是列表条目 id） */
ApiResult addToPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                        const std::string &userId, const std::string &itemId);

/** 列出用户的播放列表（带子项数量，便于列表页显示"共 N 项"） */
ApiResult getPlaylists(JellyfinApiClient &client, const std::string &userId,
                       int startIndex = 0, int limit = 100);

/**
 * 读取播放列表内容。
 *
 * 注意：`userId` 是**必填**的（设备实测 10.8.12 上缺省会返回 400）。
 * 返回条目里的 `PlaylistItemId` 是"列表条目 id"，与媒体条目 `Id` 不同 ——
 * 移除与排序都必须用它：实测用媒体 id 调删除接口会返回 204 但**什么都不删**。
 */
ApiResult getPlaylistItems(JellyfinApiClient &client, const std::string &playlistId,
                           const std::string &userId, int startIndex = 0, int limit = 200);

/** 从播放列表移除条目；`entryIds` 是逗号分隔的 `PlaylistItemId` */
ApiResult removeFromPlaylist(JellyfinApiClient &client, const std::string &playlistId,
                             const std::string &entryIds);

/** 把某个列表条目移动到新下标（0 基）；`entryId` 同样是 `PlaylistItemId` */
ApiResult movePlaylistItem(JellyfinApiClient &client, const std::string &playlistId,
                           const std::string &entryId, int newIndex);

/**
 * 删除播放列表本体（服务端就是"删除该条目"）。
 *
 * 10.8.12 没有改名路由（实测 `POST /Playlists/{id}` 返回 404），因此只提供删除。
 */
ApiResult deletePlaylist(JellyfinApiClient &client, const std::string &playlistId);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_PLAYLIST_API_H */
