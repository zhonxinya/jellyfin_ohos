# Third-party native dependencies

This tree vendors **nlohmann/json** (header-only) for Jellyfin API JSON parsing,
**mbedTLS** for `https://` transport, and **FFmpeg 7.1** for software video decode.

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

## FFmpeg (vendored, shipping)

FFmpeg **7.1** is vendored and linked; software decode is a working playback backend
(used as the fallback when the system `AVPlayer` cannot hardware-decode the stream).

Layout:

| Path | Contents |
|---|---|
| `native/third_party/ffmpeg/include/` | FFmpeg public headers |
| `native/app/entry/libs/arm64-v8a/` | Runtime `.so` for **real HarmonyOS phones** |
| `native/app/entry/libs/x86_64/` | Runtime `.so` for the DevEco emulator |

`native/app/entry/build-profile.json5` sets `abiFilters: ["arm64-v8a", "x86_64"]`, so both
ABIs are packaged into the HAP — a phone install always carries its own FFmpeg.

### Why every library ships under two names

`libav*.so` are built with versioned SONAMEs, and the loader resolves `DT_NEEDED` by the
**exact** name recorded at link time, not by the unversioned alias. Verified with `readelf -d`:

```
libavformat.so   SONAME libavformat.so.61   NEEDED libavcodec.so.61, libavutil.so.59, libz.so, libc.so
libavcodec.so    SONAME libavcodec.so.61    NEEDED libswresample.so.5, libavutil.so.59, libz.so, libc.so
libavutil.so     SONAME libavutil.so.59     NEEDED libc.so
libswscale.so    SONAME libswscale.so.8     NEEDED libavutil.so.59, libc.so
libswresample.so SONAME libswresample.so.5  NEEDED libavutil.so.59, libc.so
```

So both `libavcodec.so` (for `-lavcodec`) and `libavcodec.so.61` (for the loader) must be real
files: **HAP packaging does not preserve symlinks**, and a symlink would be dropped or
dereferenced, breaking the load at runtime.

The third copy, `libavcodec.so.61.19.100` (full version), is **not** referenced by any
`DT_NEEDED` and is dead weight in the HAP. Keep it only if you want the exact build version
visible in the package; otherwise it can be dropped to save roughly 28 MB across both ABIs.

Since these libraries are linked **dynamically** (LGPL-2.1+ compliance), update
`NOTICE` in this directory whenever the FFmpeg version changes.

### Debugging a load failure

`dlopen` failures on device usually mean a name mismatch, not a missing file. Check the
`DT_NEEDED` list of the caller against the file names actually present in
`libs/<abi>/` inside the built HAP (`unzip -l <hap> | grep libs/`).

### Verified dependency closure (arm64-v8a, HAP as built)

`readelf -d libs/arm64-v8a/libjellyfin_native.so` reports 15 `DT_NEEDED` entries. Resolving
each against the packaged `libs/arm64-v8a/` splits cleanly:

| Resolved from | Libraries |
|---|---|
| Inside the HAP | `libavformat.so.61`, `libavcodec.so.61`, `libavutil.so.59`, `libswscale.so.8`, `libswresample.so.5`, `libc++_shared.so` |
| HarmonyOS system (any device) | `libace_napi.z.so`, `libace_ndk.z.so`, `libhilog_ndk.z.so`, `libdeviceinfo_ndk.z.so`, `libEGL.so`, `libGLESv3.so`, `libnative_window.so`, `libnative_image.so`, `libc.so` |

Every FFmpeg dependency resolves from within the package, so a phone install carries its own
FFmpeg and does not rely on anything FFmpeg-related being present on the system.

## Planned: libass

`SubtitleRenderer` is a stub. Vendor libass under `native/third_party/libass/` and wire fontconfig/freetype as required by the HarmonyOS toolchain.

## License notes

Keep upstream LICENSE files next to each vendored tree. Prefer static linking for HAP size control unless system shared libraries are mandated.
