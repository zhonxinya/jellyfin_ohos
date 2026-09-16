# Third-party native dependencies

This tree currently vendors only **nlohmann/json** (header-only) for Jellyfin API JSON parsing.

## HTTPS (mbedTLS)

The built-in `HttpClient` uses **mbedTLS** (`native/third_party/mbedtls`) for `https://` Jellyfin servers.
Plain `http://` continues to use POSIX sockets.

Fetch/update mbedTLS:

```powershell
.\scripts\fetch-mbedtls.ps1
```

## Planned: libcurl (optional)

1. Place a prebuilt HarmonyOS NDK static/shared curl under `native/third_party/curl/`
   (include headers + `.a`/`.so` for the target ABI).
2. Add `JELLYFIN_HAS_CURL` compile definition in `CMakeLists.txt`.
3. Switch `HttpClient` to curl for TLS while keeping the socket client as a fallback for plain HTTP.
4. Do not commit secrets, CA private keys, or device-specific certs.

## Planned: FFmpeg

`FfmpegDecoder` 在未链接 FFmpeg 时明确返回不可用，不会伪装成可播放后端；当前基础视频播放由 ArkTS `@ohos.multimedia.media` 的系统 `AVPlayer` 负责。

1. Drop FFmpeg NDK builds under `native/third_party/ffmpeg/` (`libavcodec`, `libavformat`, `libavutil`, …).
2. Define `JELLYFIN_HAS_FFMPEG` in CMake and link the libraries.
3. Implement the real demux/decode path inside `#if defined(JELLYFIN_HAS_FFMPEG)` in `ffmpeg_decoder.cpp`.

## Planned: libass

`SubtitleRenderer` is a stub. Vendor libass under `native/third_party/libass/` and wire fontconfig/freetype as required by the HarmonyOS toolchain.

## License notes

Keep upstream LICENSE files next to each vendored tree. Prefer static linking for HAP size control unless system shared libraries are mandated.
