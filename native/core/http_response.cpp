#include "http_response.h"

#include <cctype>
#include <sstream>

namespace jellyfin {
namespace {

bool FindHeaderEnd(const std::string &raw, size_t &headerEndOut, size_t &separatorLenOut)
{
    const auto crlf = raw.find("\r\n\r\n");
    if (crlf != std::string::npos) {
        headerEndOut = crlf;
        separatorLenOut = 4;
        return true;
    }
    const auto lf = raw.find("\n\n");
    if (lf != std::string::npos) {
        headerEndOut = lf;
        separatorLenOut = 2;
        return true;
    }
    return false;
}

size_t FindLineEnd(const std::string &raw, size_t pos)
{
    const auto crlf = raw.find("\r\n", pos);
    if (crlf != std::string::npos) {
        return crlf;
    }
    const auto lf = raw.find('\n', pos);
    return lf;
}

std::string TrimAscii(std::string value)
{
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) {
        value.erase(value.begin());
    }
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) {
        value.pop_back();
    }
    return value;
}

std::string ChunkSizeToken(std::string line)
{
    line = TrimAscii(line);
    const auto semi = line.find(';');
    if (semi != std::string::npos) {
        line = line.substr(0, semi);
    }
    return TrimAscii(line);
}

size_t LineAdvance(const std::string &raw, size_t lineEnd)
{
    if (lineEnd + 1 < raw.size() && raw[lineEnd] == '\r' && raw[lineEnd + 1] == '\n') {
        return lineEnd + 2;
    }
    return lineEnd + 1;
}

bool ParseHeaders(const std::string &headers, int &statusOut, size_t &contentLengthOut, bool &chunkedOut)
{
    statusOut = 0;
    contentLengthOut = static_cast<size_t>(-1);
    chunkedOut = false;

    std::istringstream hs(headers);
    std::string statusLine;
    if (!std::getline(hs, statusLine)) {
        return false;
    }
    if (!statusLine.empty() && statusLine.back() == '\r') {
        statusLine.pop_back();
    }

    std::istringstream sl(statusLine);
    std::string httpVer;
    sl >> httpVer >> statusOut;
    if (statusOut <= 0) {
        return false;
    }

    std::string line;
    while (std::getline(hs, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        const auto colon = line.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        std::string name = line.substr(0, colon);
        std::string value = line.substr(colon + 1);
        for (char &c : name) {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        value = TrimAscii(value);
        if (name == "content-length") {
            try {
                contentLengthOut = static_cast<size_t>(std::stoul(value));
            } catch (...) {
            }
        } else if (name == "transfer-encoding") {
            std::string lower = value;
            for (char &c : lower) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            if (lower.find("chunked") != std::string::npos) {
                chunkedOut = true;
            }
        }
    }
    return true;
}

bool DecodeChunkedBody(const std::string &encoded, std::string &decoded, std::string &error)
{
    decoded.clear();
    size_t pos = 0;
    while (pos < encoded.size()) {
        const size_t lineEnd = FindLineEnd(encoded, pos);
        if (lineEnd == std::string::npos) {
            error = "Incomplete chunked body";
            return false;
        }

        const std::string sizeHex = ChunkSizeToken(encoded.substr(pos, lineEnd - pos));
        if (sizeHex.empty()) {
            error = "Invalid chunk size";
            return false;
        }

        size_t chunkSize = 0;
        try {
            chunkSize = static_cast<size_t>(std::stoul(sizeHex, nullptr, 16));
        } catch (...) {
            error = "Invalid chunk size";
            return false;
        }

        pos = LineAdvance(encoded, lineEnd);
        if (chunkSize == 0) {
            return true;
        }
        if (pos + chunkSize > encoded.size()) {
            error = "Incomplete chunked body";
            return false;
        }
        decoded.append(encoded, pos, chunkSize);
        pos += chunkSize;
        if (pos + 1 < encoded.size() && encoded[pos] == '\r' && encoded[pos + 1] == '\n') {
            pos += 2;
        } else if (pos < encoded.size() && encoded[pos] == '\n') {
            pos += 1;
        }
    }
    error = "Incomplete chunked body";
    return false;
}

bool ChunkedBodyComplete(const std::string &encoded)
{
    size_t pos = 0;
    while (pos < encoded.size()) {
        const size_t lineEnd = FindLineEnd(encoded, pos);
        if (lineEnd == std::string::npos) {
            return false;
        }
        const std::string sizeHex = ChunkSizeToken(encoded.substr(pos, lineEnd - pos));
        if (sizeHex.empty()) {
            return false;
        }
        size_t chunkSize = 0;
        try {
            chunkSize = static_cast<size_t>(std::stoul(sizeHex, nullptr, 16));
        } catch (...) {
            return false;
        }
        pos = LineAdvance(encoded, lineEnd);
        if (chunkSize == 0) {
            return true;
        }
        if (pos + chunkSize > encoded.size()) {
            return false;
        }
        pos += chunkSize;
        if (pos + 1 < encoded.size() && encoded[pos] == '\r' && encoded[pos + 1] == '\n') {
            pos += 2;
        } else if (pos < encoded.size() && encoded[pos] == '\n') {
            pos += 1;
        }
    }
    return false;
}

} // namespace

bool IsHttpResponseComplete(const std::string &raw)
{
    size_t headerEnd = 0;
    size_t separatorLen = 0;
    if (!FindHeaderEnd(raw, headerEnd, separatorLen)) {
        return false;
    }

    int status = 0;
    auto contentLength = static_cast<size_t>(-1);
    bool chunked = false;
    if (!ParseHeaders(raw.substr(0, headerEnd), status, contentLength, chunked)) {
        return false;
    }

    const std::string body = raw.substr(headerEnd + separatorLen);
    if (chunked) {
        return ChunkedBodyComplete(body);
    }
    if (contentLength != static_cast<size_t>(-1)) {
        return body.size() >= contentLength;
    }
    return true;
}

bool ParseHttpResponse(const std::string &raw, HttpResponse &resp, std::string &error)
{
    size_t headerEnd = 0;
    size_t separatorLen = 0;
    if (!FindHeaderEnd(raw, headerEnd, separatorLen)) {
        error = "Malformed HTTP response";
        return false;
    }

    const std::string headers = raw.substr(0, headerEnd);
    resp.body = raw.substr(headerEnd + separatorLen);

    auto contentLength = static_cast<size_t>(-1);
    bool chunked = false;
    if (!ParseHeaders(headers, resp.status, contentLength, chunked)) {
        error = "Invalid HTTP status";
        return false;
    }

    if (chunked) {
        std::string decoded;
        if (!DecodeChunkedBody(resp.body, decoded, error)) {
            return false;
        }
        resp.body = std::move(decoded);
    } else if (contentLength != static_cast<size_t>(-1)) {
        if (resp.body.size() < contentLength) {
            error = "Incomplete HTTP body";
            return false;
        }
        if (resp.body.size() > contentLength) {
            resp.body.resize(contentLength);
        }
    }

    return true;
}

} // namespace jellyfin
