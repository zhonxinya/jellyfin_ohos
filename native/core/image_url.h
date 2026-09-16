#ifndef JELLYFIN_CORE_IMAGE_URL_H
#define JELLYFIN_CORE_IMAGE_URL_H

#include <string>

#include <nlohmann/json.hpp>

namespace jellyfin {

/** Build authenticated Jellyfin image URL. */
std::string BuildImageUrl(const std::string &baseUrl, const std::string &itemId,
                          const std::string &imageType, int maxWidth,
                          const std::string &tag, const std::string &accessToken);

/** Extract ImageTags.Primary (or named type) from an Item JSON object. */
std::string ExtractImageTag(const nlohmann::json &item, const std::string &imageType = "Primary");

} // namespace jellyfin

#endif /* JELLYFIN_CORE_IMAGE_URL_H */
