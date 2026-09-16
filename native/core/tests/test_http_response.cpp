#include "http_response.h"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>

namespace {

int gFailures = 0;

void ExpectTrue(const char *name, bool condition)
{
    if (!condition) {
        std::cerr << "FAIL: " << name << '\n';
        ++gFailures;
    }
}

void ExpectEq(const char *name, const std::string &actual, const std::string &expected)
{
    if (actual != expected) {
        std::cerr << "FAIL: " << name << " expected='" << expected << "' actual='" << actual << "'\n";
        ++gFailures;
    }
}

void ExpectEqInt(const char *name, int actual, int expected)
{
    if (actual != expected) {
        std::cerr << "FAIL: " << name << " expected=" << expected << " actual=" << actual << '\n';
        ++gFailures;
    }
}

std::string BuildChunkedResponse(const std::string &payload)
{
    std::ostringstream sizeHex;
    sizeHex << std::hex << payload.size();
    return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + sizeHex.str() + "\r\n" +
           payload + "\r\n0\r\n\r\n";
}

} // namespace

int main()
{
    const std::string payload =
        R"({"AccessToken":"abc","User":{"Id":"uid","Name":"zxy"}})";
    const std::string raw = BuildChunkedResponse(payload);

    ExpectTrue("chunked response complete", jellyfin::IsHttpResponseComplete(raw));

    jellyfin::HttpResponse resp;
    std::string error;
    ExpectTrue("parse chunked response", jellyfin::ParseHttpResponse(raw, resp, error));
    ExpectEqInt("status", resp.status, 200);
    ExpectEq("body", resp.body, payload);

    const std::string partial = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nD3\r\n{\"partial\"";
    ExpectTrue("partial chunked incomplete", !jellyfin::IsHttpResponseComplete(partial));

    if (gFailures == 0) {
        std::cout << "All http_response tests passed.\n";
        return 0;
    }
    std::cerr << gFailures << " test(s) failed.\n";
    return 1;
}
