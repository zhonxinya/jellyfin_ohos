#include "options_parse.h"

#include "json_arg.h"

namespace jellyfin {
namespace api {

ItemsQuery ParseItemsQueryJson(const nlohmann::json &j)
{
    ItemsQuery query;
    if (!j.is_object()) {
        return query;
    }
    using jellyfin::json_arg::Bool;
    using jellyfin::json_arg::Int32;
    using jellyfin::json_arg::String;

    query.parentId = String(j, "parentId", query.parentId);
    query.startIndex = Int32(j, "startIndex", query.startIndex);
    query.limit = Int32(j, "limit", query.limit);
    query.searchTerm = String(j, "searchTerm", query.searchTerm);
    query.includeItemTypes = String(j, "includeItemTypes", query.includeItemTypes);
    query.sortBy = String(j, "sortBy", query.sortBy);
    query.sortOrder = String(j, "sortOrder", query.sortOrder);
    query.favoriteOnly = Bool(j, "favoriteOnly", query.favoriteOnly);
    query.recursive = Bool(j, "recursive", query.recursive);
    query.genreIds = String(j, "genreIds", query.genreIds);
    query.studioIds = String(j, "studioIds", query.studioIds);
    query.personIds = String(j, "personIds", query.personIds);
    query.fields = String(j, "fields", query.fields);
    query.mediaTypes = String(j, "mediaTypes", query.mediaTypes);
    query.excludeItemTypes = String(j, "excludeItemTypes", query.excludeItemTypes);
    query.enableUserData = Bool(j, "enableUserData", query.enableUserData);
    query.filters = String(j, "filters", query.filters);
    query.years = String(j, "years", query.years);
    query.officialRatings = String(j, "officialRatings", query.officialRatings);
    query.minOfficialRating = String(j, "minOfficialRating", query.minOfficialRating);
    query.tags = String(j, "tags", query.tags);
    query.videoTypes = String(j, "videoTypes", query.videoTypes);
    query.isHd = Bool(j, "isHd", query.isHd);
    query.is4k = Bool(j, "is4k", query.is4k);
    query.hasSubtitles = Bool(j, "hasSubtitles", query.hasSubtitles);
    query.enableTotalRecordCount = Bool(j, "enableTotalRecordCount", query.enableTotalRecordCount);
    // 本地随机抽样池（0 = 关闭，走服务端原生 Random 排序）。
    // 为什么由客户端抽样：服务端 RandomComparer 的比较器不自洽，会随机抛 400
    // （见 `ItemsQuery::randomSamplePoolSize` 的说明）。
    query.randomSamplePoolSize = Int32(j, "randomSamplePoolSize", query.randomSamplePoolSize);
    return query;
}

PlaybackInfoOptions ParsePlaybackOptionsJson(const nlohmann::json &j)
{
    PlaybackInfoOptions options;
    if (!j.is_object()) {
        return options;
    }
    using jellyfin::json_arg::Bool;
    using jellyfin::json_arg::Int32;

    options.audioStreamIndex = Int32(j, "audioStreamIndex", options.audioStreamIndex);
    options.subtitleStreamIndex = Int32(j, "subtitleStreamIndex", options.subtitleStreamIndex);
    options.maxStreamingBitrate = Int32(j, "maxStreamingBitrate", options.maxStreamingBitrate);
    options.enableDirectPlay = Bool(j, "enableDirectPlay", options.enableDirectPlay);
    options.enableDirectStream = Bool(j, "enableDirectStream", options.enableDirectStream);
    options.enableTranscoding = Bool(j, "enableTranscoding", options.enableTranscoding);
    // 是否带 DeviceProfile（默认带，见 PlaybackInfoOptions::includeDeviceProfile 的说明）。
    // 宿主可在"用户明确要求强制直连"等场景置 false。
    options.includeDeviceProfile = Bool(j, "includeDeviceProfile", options.includeDeviceProfile);
    return options;
}

} // namespace api
} // namespace jellyfin
