#include "playback_policy.h"

#include "url_util.h"

namespace jellyfin {
namespace player {

const char *PlayMethodToString(PlayMethod method)
{
    switch (method) {
    case PlayMethod::DirectPlay:
        return "DirectPlay";
    case PlayMethod::DirectStream:
        return "DirectStream";
    case PlayMethod::Transcode:
        return "Transcode";
    default:
        return "Unknown";
    }
}

bool ResolvePlaybackSession(const nlohmann::json &playbackInfo, const std::string &baseUrl,
                            const std::string &accessToken, PlaybackSession &out,
                            std::string &error)
{
    out = PlaybackSession{};
    if (!playbackInfo.is_object()) {
        error = "PlaybackInfo is not an object";
        return false;
    }

    if (playbackInfo.contains("PlaySessionId") && playbackInfo["PlaySessionId"].is_string()) {
        out.playSessionId = playbackInfo["PlaySessionId"].get<std::string>();
    }

    if (!playbackInfo.contains("MediaSources") || !playbackInfo["MediaSources"].is_array() ||
        playbackInfo["MediaSources"].empty()) {
        error = "No MediaSources in PlaybackInfo";
        return false;
    }

    const auto &ms = playbackInfo["MediaSources"][0];
    if (ms.contains("Id") && ms["Id"].is_string()) {
        out.mediaSourceId = ms["Id"].get<std::string>();
    }
    if (ms.contains("Container") && ms["Container"].is_string()) {
        out.container = ms["Container"].get<std::string>();
    }
    if (ms.contains("SupportsDirectPlay")) {
        out.supportsDirectPlay = ms["SupportsDirectPlay"].get<bool>();
    }
    if (ms.contains("SupportsDirectStream")) {
        out.supportsDirectStream = ms["SupportsDirectStream"].get<bool>();
    }
    if (ms.contains("SupportsTranscoding")) {
        out.supportsTranscoding = ms["SupportsTranscoding"].get<bool>();
    }
    if (ms.contains("RunTimeTicks") && ms["RunTimeTicks"].is_number()) {
        out.runtimeTicks = ms["RunTimeTicks"].get<int64_t>();
    }

    if (ms.contains("MediaStreams") && ms["MediaStreams"].is_array()) {
        for (const auto &stream : ms["MediaStreams"]) {
            if (!stream.is_object() || !stream.contains("Type")) {
                continue;
            }
            const std::string type = stream["Type"].get<std::string>();
            if (type == "Video" && stream.contains("Codec") && stream["Codec"].is_string() &&
                out.videoCodec.empty()) {
                out.videoCodec = stream["Codec"].get<std::string>();
            }
            if (type == "Audio" && stream.contains("Codec") && stream["Codec"].is_string() &&
                out.audioCodec.empty()) {
                out.audioCodec = stream["Codec"].get<std::string>();
            }
        }
    }

    // Prefer TranscodingUrl when present.
    if (ms.contains("TranscodingUrl") && ms["TranscodingUrl"].is_string()) {
        const std::string t = ms["TranscodingUrl"].get<std::string>();
        if (!t.empty()) {
            out.method = PlayMethod::Transcode;
            if (t.rfind("http://", 0) == 0 || t.rfind("https://", 0) == 0) {
                out.playUrl = t;
            } else {
                out.playUrl = JoinUrl(baseUrl, t);
            }
        }
    }

    if (out.playUrl.empty()) {
        std::string itemId;
        if (playbackInfo.contains("ItemId") && playbackInfo["ItemId"].is_string()) {
            itemId = playbackInfo["ItemId"].get<std::string>();
        }
        out.itemId = itemId;
        if (itemId.empty()) {
            error = "Missing ItemId for static stream";
            return false;
        }
        std::string path = "/Videos/" + itemId + "/stream?static=true";
        if (!out.mediaSourceId.empty()) {
            path += "&MediaSourceId=" + out.mediaSourceId;
        }
        if (!accessToken.empty()) {
            path += "&api_key=" + accessToken;
        }
        out.playUrl = JoinUrl(baseUrl, path);
        if (out.supportsDirectPlay) {
            out.method = PlayMethod::DirectPlay;
        } else if (out.supportsDirectStream) {
            out.method = PlayMethod::DirectStream;
        } else {
            out.method = PlayMethod::DirectStream;
        }
    }

    if (out.itemId.empty() && playbackInfo.contains("ItemId") &&
        playbackInfo["ItemId"].is_string()) {
        out.itemId = playbackInfo["ItemId"].get<std::string>();
    }

    if (out.playUrl.empty()) {
        error = "Could not resolve play URL";
        return false;
    }
    return true;
}

} // namespace player
} // namespace jellyfin
