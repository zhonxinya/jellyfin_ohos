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

## FFmpeg (source vendored, compiled into the app)

FFmpeg **7.1** is vendored **as source** and compiled into the app; software decode is a working
playback backend (used as the fallback when the system `AVPlayer` cannot hardware-decode the stream).

Layout:

| Path | Contents | In git? |
|---|---|---|
| `native/third_party/ffmpeg/source/` | Pristine upstream FFmpeg 7.1 source tree (8540 files, ~101 MB) | yes |
| `native/third_party/ffmpeg/include/` | Public headers consumed by this project | yes |
| `native/app/entry/libs/arm64-v8a/` | Runtime `.so` for **real HarmonyOS phones** | yes (prebuilt) |
| `native/app/entry/libs/x86_64/` | Runtime `.so` for the DevEco emulator | yes (prebuilt) |
| `native/third_party/ffmpeg/build-stamp-<abi>.txt` | Fingerprint of the source/script that produced the `.so` above | yes |

`native/app/entry/build-profile.json5` sets `abiFilters: ["arm64-v8a", "x86_64"]`, so both
ABIs are packaged into the HAP — a phone install always carries its own FFmpeg.

### How the source gets compiled

**The compiled libraries are committed**, so a fresh clone builds both ABIs with no
HarmonyOS toolchain work and no FFmpeg compile step. Compiling only happens when you want to
*refresh* the binaries: when the libraries (or the stamp) are missing/stale,
`native/app/entry/src/main/cpp/CMakeLists.txt` invokes `scripts/build_ffmpeg_ohos.sh` for the
target ABI before linking, and the script can also be run by hand:

```bash
# 克隆后通常什么都不用做：预编译库已入库，构建应用直接链接
bash scripts/build_ffmpeg_ohos.sh all               # 显式重新编译（指纹不符时才会真正编译）
FFMPEG_FORCE_REBUILD=1 bash scripts/build_ffmpeg_ohos.sh all     # 无条件重建
```

### Prebuilt shared libraries are committed

Both ABIs ship in git (`native/app/entry/libs/x86_64/` + `arm64-v8a/`, 5 libraries × 3 names
each). Git stores one object per unique content, and the three names of a library are
byte-identical copies — so the committed payload is the 10 unique libraries: **27.3 MB** of
unique content, ≈14.5 MB in the object store (shared libraries compress to about half), not
the 83 MB the working tree appears to hold.

Consequences worth knowing:

- **Fresh clones and CI need no cross toolchain.** Link-time resolution finds
  `native/app/entry/libs/<abi>/libavcodec.so` immediately; the build never enters the
  `configure`/`make` path unless the binaries are genuinely stale.
- **Staleness is decided by a fingerprint, not by mtime.** `git clone` gives every file nearly
  the same timestamp, which would make the source tree look "newer" than the binaries and
  trigger a pointless ~6 minute rebuild (both ABIs). Each ABI therefore has a committed
  `build-stamp-<abi>.txt` recording: FFmpeg version, ABI, `sha256` of
  `scripts/build_ffmpeg_ohos.sh`, and the git tree object id of
  `native/third_party/ffmpeg/source`. Same fingerprint ⇒ the script prints
  `跳过 <abi>（指纹一致，产物已是最新）`; changed script, changed source tree, hand-edited (dirty)
  source, or a missing stamp ⇒ rebuild. Outside a git checkout the script falls back to the
  old mtime comparison.
- **A refresh dirties the working tree on purpose.** After a real rebuild,
  `git status` shows the changed `.so` files plus the updated stamp. Commit them together if
  the refresh was intended; otherwise `git checkout -- native/app/entry/libs
  native/third_party/ffmpeg/build-stamp-*.txt`.
- **LGPL-2.1+ compliance is unchanged and now more auditable.** The binaries are committed
  next to the *complete corresponding source* they were built from, and the stamp pins the
  exact source tree and build script — so the "how was this binary produced" question is
  answerable from the repository alone.

Notes on the design:

- **The vendored tree is never built in place.** Each build copies `source/` into a scratch
  directory (`<repo 父目录>/_ffmpeg-build/out/work-<abi>`) and runs `configure`/`make` there, so
  `native/third_party/ffmpeg/source/` stays byte-for-byte upstream — that keeps diffs and future
  version bumps reviewable.
- **Rebuilds are incremental.** The script skips an ABI whose committed fingerprint still
  matches (see above), so only an actual script/source change pays the cost. One ABI takes
  ~3 minutes on a 16-core host. Force with `FFMPEG_FORCE_REBUILD=1`.
- **Toolchain discovery is path-independent.** The script probes `OHOS_COMMAND_LINE_TOOLS`, then
  `command-line-tools/` inside the repo (CI layout), then `_harmony-tools/command-line-tools`
  up to four levels above the repo, then common DevEco locations — because the auto-build is
  invoked from CMake, where the working directory is not predictable.
- **Disable the auto-build** with `-DJELLYFIN_FFMPEG_AUTOBUILD=OFF` when you only want to
  syntax-check the HAP build (the project then compiles without `JELLYFIN_HAS_FFMPEG`, and
  `FfmpegDecoder` honestly reports decode-as-unavailable rather than pretending to work).
- **Shared, not static.** LGPL-2.1-or-later compliance is why these are shared libraries;
  see `NOTICE` and `native/feature/player/README.md`.

Config rationale (unchanged from the original build): only the decode-side components are kept
(`libavformat`/`libavcodec`/`libavutil`/`libswscale`/`libswresample`; no encoders, muxers,
filters, devices, programs or docs), `--disable-network` because stream fetching goes through
this project's own HTTP client (mbedTLS + Jellyfin auth) via a custom `AVIOContext`, and
`--disable-asm` because the HarmonyOS cross toolchain has no reliable nasm/yasm.


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
