#include "range_fetcher.h"

#include <mutex>

namespace jellyfin {
namespace player {
namespace {

std::mutex g_fetcherMutex;
RangeFetchFn g_fetcher;

} // namespace

void SetRangeFetcher(RangeFetchFn fn)
{
    std::lock_guard<std::mutex> lock(g_fetcherMutex);
    g_fetcher = std::move(fn);
}

bool HasRangeFetcher()
{
    std::lock_guard<std::mutex> lock(g_fetcherMutex);
    return static_cast<bool>(g_fetcher);
}

RangeResponse FetchRange(const std::string &url, int64_t start, int64_t end)
{
    RangeFetchFn fn;
    {
        std::lock_guard<std::mutex> lock(g_fetcherMutex);
        fn = g_fetcher;
    }
    if (!fn) {
        RangeResponse response;
        response.error = "未注入 RangeFetcher：请在宿主启动时调用 SetRangeFetcher()";
        return response;
    }
    return fn(url, start, end);
}

} // namespace player
} // namespace jellyfin
