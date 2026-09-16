#!/usr/bin/env bash
#
# 为 HarmonyOS/OpenHarmony 交叉编译 FFmpeg（软解码用）。
#
# 设计要点：
# - **共享库**（LGPL-2.1+ 要求动态链接；同时避免与 GPL 组件冲突）
# - 只保留解码所需组件：libavformat / libavcodec / libavutil / libswscale / libswresample
#   关闭 encoders / muxers / filters / avdevice / postproc / programs / doc（显著减小体积）
# - **--disable-network**：不使用 FFmpeg 自带的 http/tls 协议栈。
#   取流由本工程 `native/core` 的 HTTP 客户端（含 mbedTLS，支持 https）完成，
#   再通过自定义 AVIOContext 喂给 libavformat —— 这样 https 与 Jellyfin 鉴权头都能复用既有实现。
# - 关闭 asm：HarmonyOS 交叉编译环境没有可靠的 nasm/yasm，C 实现足够（软解本来就不追求极致速度）
#
# 用法：
#   scripts/build_ffmpeg_ohos.sh [x86_64|arm64-v8a|all] [输出目录]
# 默认输出：$HOME/_ffmpeg-build/out/<abi>
#
# 产物（每个 ABI）：
#   out/<abi>/lib/libavcodec.so, libavformat.so, libavutil.so, libswscale.so, libswresample.so
#   out/<abi>/include/...
set -euo pipefail

ABI_ARG="${1:-all}"

# 路径默认值基于脚本自身位置推导（环境无关）：脚本位于 <repo>/scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="${FFMPEG_WORK_ROOT:-$(dirname "$REPO_ROOT")/_ffmpeg-build}"
OUT_ROOT="${2:-${FFMPEG_OUT_ROOT:-$WORK_ROOT/out}}"

FFMPEG_VERSION="7.1"
SRC_TARBALL="${FFMPEG_SRC_TARBALL:-$WORK_ROOT/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
SRC_SHA256="40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6"

TOOLS_ROOT="${OHOS_COMMAND_LINE_TOOLS:-$(dirname "$REPO_ROOT")/_harmony-tools/command-line-tools}"
SDK_NATIVE="$TOOLS_ROOT/sdk/default/openharmony/native"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
SYSROOT="$SDK_NATIVE/sysroot"

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

die() { echo "错误：$*" >&2; exit 1; }

[ -d "$LLVM_BIN" ] || die "找不到 OHOS LLVM 工具链：$LLVM_BIN（可用 OHOS_COMMAND_LINE_TOOLS 覆盖）"
[ -d "$SYSROOT" ] || die "找不到 OHOS sysroot：$SYSROOT"
[ -f "$SRC_TARBALL" ] || die "找不到 FFmpeg 源码包：$SRC_TARBALL"

# 校验源码包完整性（供应链可追溯）
echo "校验 $SRC_TARBALL"
echo "$SRC_SHA256  $SRC_TARBALL" | sha256sum -c - >/dev/null || die "FFmpeg 源码包 sha256 不匹配"

build_abi() {
    local abi="$1" arch triple sysroot_lib cpu
    case "$abi" in
        # --cpu 会被 FFmpeg 转成 -march=<值>：x86 必须写成 x86-64（clang 不认 "x86_64"），
        # aarch64 用 armv8-a（HarmonyOS 设备基线）
        x86_64)   arch="x86_64";  triple="x86_64-unknown-linux-ohos";  cpu="x86-64" ;;
        arm64-v8a) arch="aarch64"; triple="aarch64-unknown-linux-ohos"; cpu="armv8-a" ;;
        *) die "不支持的 ABI：$abi（仅支持 x86_64 / arm64-v8a）" ;;
    esac
    sysroot_lib="$SYSROOT/usr/lib/${arch}-linux-ohos"

    local work="$OUT_ROOT/work-$abi"
    local prefix="$OUT_ROOT/$abi"
    echo "==================== 构建 $abi（$triple） ===================="

    rm -rf "$work" "$prefix"
    mkdir -p "$work" "$prefix"
    tar -xf "$SRC_TARBALL" -C "$work" --strip-components=1

    pushd "$work" >/dev/null

    # 常用解码器/解复用器/解析器（媒体库常见格式：mkv/mp4/ts/webm + h264/hevc/av1/vp9 + 常见音频）
    local decoders="h264,hevc,mpeg2video,mpeg4,msmpeg4v3,vc1,wmv3,vp8,vp9,av1,theora,flv,mjpeg,prores,\
aac,aac_latm,ac3,eac3,dca,truehd,mlp,flac,mp3,opus,vorbis,alac,pcm_s16le,pcm_s24le,pcm_bluray,pcm_dvd,pcm_f32le,\
subrip,ass,ssa,dvd_subtitle,hdmv_pgs_subtitle,webvtt,text"
    local demuxers="matroska,mov,mp4,mpegts,mpegps,avi,flv,asf,ogg,wav,flac,mp3,webm_dash_manifest,\
hls,concat,image2,srt,ass,webvtt_raw,sup,pgs"
    local parsers="h264,hevc,mpeg4video,mpegvideo,vc1,vp9,av1,aac,ac3,dca,flac,mpegaudio,opus,vorbis"

    ./configure \
        --prefix="$prefix" \
        --target-os=linux \
        --arch="$arch" \
        --cpu="$cpu" \
        --enable-cross-compile \
        --cc="$LLVM_BIN/${triple}-clang" \
        --cxx="$LLVM_BIN/${triple}-clang++" \
        --ar="$LLVM_BIN/llvm-ar" \
        --nm="$LLVM_BIN/llvm-nm" \
        --ranlib="$LLVM_BIN/llvm-ranlib" \
        --strip="$LLVM_BIN/llvm-strip" \
        --sysroot="$SYSROOT" \
        --extra-cflags="--sysroot=$SYSROOT -I$SYSROOT/usr/include -fPIC -O2" \
        --extra-ldflags="--sysroot=$SYSROOT -L$sysroot_lib -Wl,-rpath-link,$sysroot_lib" \
        --enable-shared \
        --disable-static \
        --enable-pic \
        --disable-asm \
        --disable-programs \
        --disable-doc \
        --disable-network \
        --disable-avdevice \
        --disable-postproc \
        --disable-avfilter \
        --disable-encoders \
        --disable-muxers \
        --disable-bsfs \
        --disable-filters \
        --disable-devices \
        --disable-hwaccels \
        --disable-vulkan \
        --disable-vaapi \
        --disable-vdpau \
        --disable-cuda-llvm \
        --disable-nvdec \
        --disable-nvenc \
        --disable-d3d11va \
        --disable-dxva2 \
        --disable-mediacodec \
        --disable-videotoolbox \
        --disable-libdrm \
        --enable-protocol=file \
        --disable-iconv \
        --enable-encoder=png,mjpeg \
        --enable-muxer=image2 \
        --enable-decoder="${decoders}" \
        --enable-demuxer="${demuxers}" \
        --enable-parser="${parsers}" \
        > "$OUT_ROOT/configure-$abi.log" 2>&1 || { tail -30 "$OUT_ROOT/configure-$abi.log"; die "configure 失败（$abi），日志：$OUT_ROOT/configure-$abi.log"; }

        make -j"$BUILD_JOBS" > "$OUT_ROOT/make-$abi.log" 2>&1 || { tail -30 "$OUT_ROOT/make-$abi.log"; die "make 失败（$abi），日志：$OUT_ROOT/make-$abi.log"; }
        make install > "$OUT_ROOT/install-$abi.log" 2>&1 || { tail -20 "$OUT_ROOT/install-$abi.log"; die "make install 失败（$abi）"; }

    popd >/dev/null
    echo "---- $abi 产物 ----"
    ls -1 "$prefix/lib" | sed 's/^/    /'
    echo "    （大小：$(du -sh "$prefix" | cut -f1)）"

    # 部署到仓库内的标准位置，使任意构建（含 CI 与本地副本构建）都能相对路径找到：
    #   native/app/entry/libs/<abi>/           → 共享库（hvigor 会打进 HAP；已在 .gitignore 中忽略）
    #   third_party/ffmpeg/include/            → 公开头文件（随仓库提交，便于第三方源码构建）
    if [ "${FFMPEG_SKIP_DEPLOY:-0}" != "1" ]; then
        local libs_dir="$REPO_ROOT/native/app/entry/libs/$abi"
        local inc_dir="$REPO_ROOT/native/third_party/ffmpeg/include"
        mkdir -p "$libs_dir" "$inc_dir"
        # -L 跟随符号链接，落盘为真实文件；必须同时保留三种名字：
        #   libX.so（链接用）、libX.so.<major>（**运行时 SONAME**，动态链接器按它查找）、libX.so.<full>
        for f in libavformat libavcodec libavutil libswscale libswresample; do
            cp -Lf "$prefix/lib/$f.so" "$libs_dir/$f.so"
            local soname
            soname="$(readelf -d "$prefix/lib/$f.so" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
            if [ -n "$soname" ]; then
                cp -Lf "$prefix/lib/$soname" "$libs_dir/$soname"
            fi
            local ver
            ver="$(readlink -f "$prefix/lib/$f.so" | xargs -r basename)"
            if [ -n "$ver" ] && [ "$ver" != "$f.so" ]; then
                cp -Lf "$prefix/lib/$ver" "$libs_dir/$ver"
            fi
        done
        cp -Rf "$prefix/include/." "$inc_dir/"
        echo "---- 部署完成 ----"
        echo "    库：$libs_dir"
        echo "    头：$inc_dir"
    fi
}

case "$ABI_ARG" in
    all) build_abi x86_64; build_abi arm64-v8a ;;
    *)   build_abi "$ABI_ARG" ;;
esac

echo "完成。产物目录：$OUT_ROOT"
