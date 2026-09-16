#ifndef JELLYFIN_CORE_ERROR_H
#define JELLYFIN_CORE_ERROR_H

#include <string>

namespace jellyfin {

struct JellyfinError {
    int statusCode = 0;
    std::string message;
};

inline bool IsOk(const JellyfinError &err)
{
    return err.message.empty() && err.statusCode >= 200 && err.statusCode < 300;
}

} // namespace jellyfin

#endif /* JELLYFIN_CORE_ERROR_H */
