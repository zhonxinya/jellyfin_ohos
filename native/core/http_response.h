#ifndef JELLYFIN_CORE_HTTP_RESPONSE_H
#define JELLYFIN_CORE_HTTP_RESPONSE_H

#include "http_client.h"

#include <string>

namespace jellyfin {

/** Returns true when headers and body (Content-Length or chunked terminator) look complete. */
bool IsHttpResponseComplete(const std::string &raw);

/** Parse raw HTTP/1.1 bytes into status + decoded body. */
bool ParseHttpResponse(const std::string &raw, HttpResponse &resp, std::string &error);

} // namespace jellyfin

#endif /* JELLYFIN_CORE_HTTP_RESPONSE_H */
