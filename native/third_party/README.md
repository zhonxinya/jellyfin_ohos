# Third-party native dependencies

This tree vendors **nlohmann/json** (header-only) for Jellyfin API JSON parsing,
**mbedTLS** for `https://` transport, **FFmpeg 8.0** for software video decode, and
**dav1d 1.5.1** for AV1 software decode (linked into FFmpeg as the `libdav1d` decoder).

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

FFmpeg **8.0** is vendored **as source** and compiled into the app; software decode is a working
playback backend (used as the fallback when the system `AVPlayer` cannot hardware-decode the stream).

Layout:

| Path | Contents | In git? |
|---|---|---|
| `native/third_party/ffmpeg/source/` | Pristine upstream FFmpeg 8.0 source tree (9912 files, ~108 MB; 上游 n8.0 标签归档，版本在 `RELEASE`) | yes |
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

Both ABIs ship in git (`native/app/entry/libs/x86_64/` + `arm64-v8a/`, 5 libraries × 2 names
each: `libX.so` for linking and `libX.so.<major>`, the SONAME the loader looks up). The two
names of a library are byte-identical copies — so the payload is the 10 unique libraries:
**28.9 MB** of unique content, ≈14.5 MB in the object store (shared libraries compress to about
half), not the 57.8 MB the working tree appears to hold.

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
- **`abiFilters` decides what gets *compiled*, not what gets *packaged*.** Verified on
  2026-09-18 with a scratch build: a module target configured for `abiFilters: ["arm64-v8a"]`
  only built that ABI, but hvigor still packaged every `libs/<abi>/` directory that existed on
  disk — so the emulator libs would have ridden along into a "phone-only" package. The release
  workflow therefore moves `libs/x86_64` aside before building the arm64 product, and
  `scripts/verify_hap_ffmpeg.sh` fails the release if an unexpected ABI payload is present.
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
# FFmpeg 8.0（7.1 → 8.0 升级后 SONAME 全部进位）
libavformat.so   SONAME libavformat.so.62   NEEDED libavcodec.so.62, libavutil.so.60, libz.so, libc.so
libavcodec.so    SONAME libavcodec.so.62    NEEDED libswresample.so.6, libavutil.so.60, libdav1d.so.7,
                                                   libnative_media_vdec.so, libnative_media_codecbase.so,
                                                   libnative_media_core.so, libz.so, libc.so
libavutil.so     SONAME libavutil.so.60     NEEDED libc.so
libswscale.so    SONAME libswscale.so.9     NEEDED libavutil.so.60, libc.so
libswresample.so SONAME libswresample.so.6  NEEDED libavutil.so.60, libc.so
```

`libavcodec.so` 里那几个 `libnative_media_*.so` 就是**鸿蒙编解码框架**（OH_AVCodec）——
它们来自 `--enable-ohcodec`，是"FFmpeg 能走设备硬解"的标志；详细说明见
`docs/ffmpeg-8-ohcodec.md`。**升级 FFmpeg 时部署脚本会先删掉旧的 `libav*.so.*`**，
避免新旧两套 SONAME 同时躺在 `libs/<abi>/` 里被打进 HAP。

So both `libavcodec.so` (for `-lavcodec`) and `libavcodec.so.62` (for the loader) must be real
files: **HAP packaging does not preserve symlinks**, and a symlink would be dropped or
dereferenced, breaking the load at runtime.

The third copy FFmpeg installs — the full version, e.g. `libavcodec.so.62.x.y` — is **not**
referenced by any `DT_NEEDED`, so the build script deliberately does not deploy it: shipping it
would put a second, identical-size copy of every library into every HAP (28.9 MB across both
ABIs). If you find such files in `libs/<abi>/` from an older build, they can be deleted safely.

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
| Inside the HAP | `libavformat.so.62`, `libavcodec.so.62`, `libavutil.so.60`, `libswscale.so.9`, `libswresample.so.6`, `libdav1d.so.7`, `libc++_shared.so` |
| HarmonyOS system (any device) | `libace_napi.z.so`, `libace_ndk.z.so`, `libhilog_ndk.z.so`, `libdeviceinfo_ndk.z.so`, `libEGL.so`, `libGLESv3.so`, `libnative_window.so`, `libnative_image.so`, `libnative_media_vdec.so`, `libnative_media_codecbase.so`, `libnative_media_core.so`, `libc.so` |

Every FFmpeg dependency resolves from within the package, so a phone install carries its own
FFmpeg and does not rely on anything FFmpeg-related being present on the system.

## dav1d (AV1 software decode; source vendored, compiled into the app)

FFmpeg is built with `--enable-libdav1d`, and the player prefers `libdav1d` for AV1. This is
**not** an optional nicety — FFmpeg's own `av1` decoder cannot software-decode at all in this
build (see `native/feature/player/README.md` → 「AV1 软解」 for the full root cause and the
device/host evidence).

Layout (mirrors the FFmpeg layout):

| Path | Contents | In git? |
|---|---|---|
| `native/third_party/dav1d/source/` | Pristine upstream dav1d 1.5.1 source tree (359 files, ~12 MB) | yes |
| `native/third_party/dav1d/include/` | Public headers (`dav1d/dav1d.h`) | yes |
| `native/app/entry/libs/<abi>/libdav1d.so{,7}` | Runtime `.so` for each ABI | yes (prebuilt) |
| `native/third_party/dav1d/build-stamp-<abi>.txt` | Fingerprint of the source/script that produced the `.so` | yes |

Build / refresh:

```bash
bash scripts/build_dav1d_ohos.sh all              # 指纹一致时直接跳过
DAV1D_FORCE_REBUILD=1 bash scripts/build_dav1d_ohos.sh all   # 无条件重建
```

Notes:

- **Toolchain**: meson + ninja (dav1d builds with meson). `meson` is not part of the HarmonyOS
  command-line tools — install it with `pip3 install --user meson` (the script also looks in
  `~/.local/bin`), `ninja` comes from the distro.
- **asm**: `arm64-v8a` builds **with** assembly (clang assembles dav1d's `.S` files; no nasm
  needed). `x86_64` builds **without** assembly, because dav1d's x86 path requires nasm, which
  neither this project nor the CI image has (same reason FFmpeg is configured `--disable-asm`).
  The emulator's AV1 decode is therefore C-only — still multi-threaded and far faster than
  FFmpeg's built-in decoder, and only the emulator is affected.
- **FFmpeg needs pkg-config to find dav1d** and the HarmonyOS toolchain has none. The FFmpeg
  script therefore points `--pkg-config` at `scripts/pkg-config-shim.sh` (a ~100-line bash
  replacement that answers exactly the queries `configure` makes) and generates a per-ABI
  `dav1d.pc` in the build directory (paths are computed per build, so no machine-specific path
  is ever committed).
- **Fingerprints are chained**: the FFmpeg stamp records the sha256 of the deployed
  `libdav1d.so`, so refreshing dav1d forces FFmpeg to relink instead of silently keeping an
  older binary. `scripts/verify_hap_ffmpeg.sh` also fails a release HAP whose `libavcodec.so`
  does not need `libdav1d.so.7`, or which is missing that library.

## Planned: libass

`SubtitleRenderer` is a stub. Vendor libass under `native/third_party/libass/` and wire fontconfig/freetype as required by the HarmonyOS toolchain.

## License notes

Keep upstream LICENSE files next to each vendored tree. Prefer static linking for HAP size control unless system shared libraries are mandated.
