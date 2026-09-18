#!/usr/bin/env bash
#
# 从**仓库内的 FFmpeg 源码**为 HarmonyOS/OpenHarmony 交叉编译 FFmpeg（软解码用）。
#
# 源码位置：native/third_party/ffmpeg/source/ （随仓库提交的 FFmpeg 7.1 原始源码）
# 产物位置（均随仓库提交，克隆后无需重新编译即可构建）：
#   native/app/entry/libs/<abi>/*.so            共享库（x86_64 + arm64-v8a，各 5 个库 × 2 个名字）
#   native/third_party/ffmpeg/include/          公开头文件
#   native/third_party/ffmpeg/build-stamp-<abi>.txt   本次编译的指纹（源码树 + 本脚本），用于跳过无谓重编译
#
# 设计要点：
# - **共享库**（LGPL-2.1+ 要求动态链接；同时避免与 GPL 组件冲突）
# - 只保留解码所需组件：libavformat / libavcodec / libavutil / libswscale / libswresample
#   关闭 encoders / muxers / filters / avdevice / postproc / programs / doc（显著减小体积）
# - **--disable-network**：不使用 FFmpeg 自带的 http/tls 协议栈。
#   取流由本工程 `native/core` 的 HTTP 客户端（含 mbedTLS，支持 https）完成，
#   再通过自定义 AVIOContext 喂给 libavformat —— 这样 https 与 Jellyfin 鉴权头都能复用既有实现。
# - 关闭 asm：HarmonyOS 交叉编译环境没有可靠的 nasm/yasm，C 实现足够（软解本来就不追求极致速度）
# - **不在源码树内构建**：每次构建把 vendored 源码复制到临时工作目录再 configure/make，
#   保证 third_party/ffmpeg/source 始终是未经改动的原始上游源码（便于 diff 与升级）。
#
# 用法：
#   scripts/build_ffmpeg_ohos.sh [x86_64|arm64-v8a|all] [输出目录]
# 默认输出：<repo 父目录>/_ffmpeg-build/out/<abi>（仅作中间产物，不参与打包）
#
# 环境变量：
#   FFMPEG_FORCE_REBUILD=1   忽略指纹判断，强制重建
#   FFMPEG_SKIP_DEPLOY=1     只构建到输出目录，不部署进仓库
#   BUILD_JOBS=N             并行编译任务数（默认 nproc）
#   OHOS_COMMAND_LINE_TOOLS  HarmonyOS 命令行工具根目录
set -euo pipefail

ABI_ARG="${1:-all}"

# 路径默认值基于脚本自身位置推导（环境无关）：脚本位于 <repo>/scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="${FFMPEG_WORK_ROOT:-$(dirname "$REPO_ROOT")/_ffmpeg-build}"
OUT_ROOT="${2:-${FFMPEG_OUT_ROOT:-$WORK_ROOT/out}}"

FFMPEG_VERSION="7.1"
# 上游发行包校验值，用于溯源（本仓库直接内置其解压后的源码树）
FFMPEG_SRC_TARBALL_SHA256="40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6"
SRC_DIR="$REPO_ROOT/native/third_party/ffmpeg/source"

# ── 定位 HarmonyOS 命令行工具链 ───────────────────────────────────────────────
# 工具链在不同环境下位置不同，且本脚本会被"应用构建"自动调用（此时 CWD 不可预期），
# 因此这里按候选位置逐个探测，而不是只认一个默认路径：
#   1) OHOS_COMMAND_LINE_TOOLS 显式指定
#   2) CI：工具链下载在**仓库内**的 command-line-tools/
#   3) 本沙箱/本地：仓库之上若干层的 _harmony-tools/command-line-tools
#   4) DevEco 常见安装位置
find_tools_root() {
    if [ -n "${OHOS_COMMAND_LINE_TOOLS:-}" ]; then
        if [ -d "$OHOS_COMMAND_LINE_TOOLS/sdk" ]; then
            printf '%s\n' "$OHOS_COMMAND_LINE_TOOLS"; return 0
        fi
        echo "警告：OHOS_COMMAND_LINE_TOOLS=$OHOS_COMMAND_LINE_TOOLS 下没有 sdk/，继续自动探测" >&2
    fi
    local d="$REPO_ROOT" i=0 cand
    while [ "$i" -lt 4 ]; do
        for cand in "$d/command-line-tools" "$d/_harmony-tools/command-line-tools"; do
            if [ -d "$cand/sdk" ]; then printf '%s\n' "$cand"; return 0; fi
        done
        d="$(dirname "$d")"
        i=$((i + 1))
    done
    for cand in "$HOME/command-line-tools" "$HOME/_harmony-tools/command-line-tools" \
                "/opt/command-line-tools" "/opt/harmony/command-line-tools"; do
        if [ -d "$cand/sdk" ]; then printf '%s\n' "$cand"; return 0; fi
    done
    return 1
}

TOOLS_ROOT="$(find_tools_root || true)"
[ -n "$TOOLS_ROOT" ] || die "找不到 HarmonyOS 命令行工具链（可设 OHOS_COMMAND_LINE_TOOLS 指定其根目录）"
SDK_NATIVE="$TOOLS_ROOT/sdk/default/openharmony/native"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
SYSROOT="$SDK_NATIVE/sysroot"

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

die() { echo "错误：$*" >&2; exit 1; }

[ -d "$LLVM_BIN" ] || die "找不到 OHOS LLVM 工具链：$LLVM_BIN（可用 OHOS_COMMAND_LINE_TOOLS 覆盖）"
[ -d "$SYSROOT" ] || die "找不到 OHOS sysroot：$SYSROOT"

# ── 源码完整性检查 ────────────────────────────────────────────────────────────
# 内置的是"解压后的源码树"而非 tarball，无法对整棵树做单值 sha256 校验，
# 因此检查关键文件是否齐全（上游发行包 sha256 见上方常量，用于溯源）。
[ -d "$SRC_DIR" ] || die "找不到内置 FFmpeg 源码：$SRC_DIR"
[ -x "$SRC_DIR/configure" ] || die "FFmpeg 源码树不完整：缺少可执行的 configure（$SRC_DIR）"
for required in Makefile VERSION libavcodec/allcodecs.c libavformat/allformats.c libavutil/avutil.h; do
    [ -f "$SRC_DIR/$required" ] || die "FFmpeg 源码树不完整：缺少 $required"
done
[ "$(cat "$SRC_DIR/VERSION")" = "$FFMPEG_VERSION" ] \
    || die "内置 FFmpeg 版本与预期不符：期望 $FFMPEG_VERSION，实际 $(cat "$SRC_DIR/VERSION")"
echo "源码：$SRC_DIR（FFmpeg $FFMPEG_VERSION，$(find "$SRC_DIR" -type f | wc -l) 个文件）"

# ── 是否需要重建 ──────────────────────────────────────────────────────────────
# 产物已随仓库提交，"是否最新"就不能只看 mtime：git clone 会给所有文件几乎相同的时间戳，
# 内置源码往往比产物"新"，于是每次克隆都要白编译一遍（16 核约 3 分钟/ABI）。
# 因此改为按**指纹**判断——stamp 文件记录（ABI + FFmpeg 版本 + 本脚本内容 sha256 + 内置源码树的 git tree oid）：
#   指纹一致                    ⇒ 现有 .so 就是"当前源码 + 当前脚本"编译出来的，直接跳过
#   指纹不符 / stamp 缺失        ⇒ 重建
#   内置源码工作区被手工改脏      ⇒ 重建（tree oid 表达不了未提交改动）
# 不在 git 仓库里（例如导出的源码快照）时，退化为原来的 mtime 比较。
stamp_path() { printf '%s/build-stamp-%s.txt' "$REPO_ROOT/native/third_party/ffmpeg" "$1"; }

source_tree_id() {
    git -C "$REPO_ROOT" rev-parse --verify --quiet "HEAD:native/third_party/ffmpeg/source" 2>/dev/null \
        || echo nogit
}

source_tree_dirty() {
    [ "$(source_tree_id)" = "nogit" ] && return 1
    [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- \
             native/third_party/ffmpeg/source 2>/dev/null)" ]
}

build_fingerprint() {
    local abi="$1"
    printf 'abi=%s\nffmpeg=%s\nscript_sha256=%s\nsource_tree=%s\n' \
        "$abi" "$FFMPEG_VERSION" \
        "$(sha256sum "$SCRIPT_DIR/build_ffmpeg_ohos.sh" | awk '{print $1}')" \
        "$(source_tree_id)"
}

needs_build() {
    local abi="$1" deployed_lib="$2" stamp
    [ "${FFMPEG_FORCE_REBUILD:-0}" = "1" ] && return 0
    [ -f "$deployed_lib" ] || return 0
    if [ "$(source_tree_id)" != "nogit" ]; then
        source_tree_dirty && return 0
        stamp="$(stamp_path "$abi")"
        [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(build_fingerprint "$abi")" ] && return 1
        return 0
    fi
    # 无 git：退回 mtime 判定（源码/本脚本比产物新 ⇒ 重建）。
    # 用绝对路径（$SCRIPT_DIR 由 cd+pwd 求得）：调用方可能不在仓库根目录，
    # 相对路径会让 find 找不到本脚本，从而静默漏判"脚本自身已改动"。
    if [ -n "$(find "$SRC_DIR" "$SCRIPT_DIR/build_ffmpeg_ohos.sh" -newer "$deployed_lib" -print -quit 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

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
    local libs_dir="$REPO_ROOT/native/app/entry/libs/$abi"
    local inc_dir="$REPO_ROOT/native/third_party/ffmpeg/include"

    if [ "${FFMPEG_SKIP_DEPLOY:-0}" != "1" ] && ! needs_build "$abi" "$libs_dir/libavcodec.so"; then
        echo "==================== 跳过 $abi（指纹一致，产物已是最新） ===================="
        return 0
    fi

    echo "==================== 构建 $abi（$triple） ===================="

    # 复制内置源码到工作目录再构建：vendored 源码树保持原始状态
    rm -rf "$work" "$prefix"
    mkdir -p "$work" "$prefix"
    cp -a "$SRC_DIR/." "$work/"

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
    #   native/app/entry/libs/<abi>/           → 共享库（hvigor 会打进 HAP；**随仓库提交**）
    #   third_party/ffmpeg/include/            → 公开头文件（随仓库提交，便于第三方源码构建）
    #   third_party/ffmpeg/build-stamp-<abi>.txt → 指纹（随仓库提交；下次构建据此跳过重编译）
    if [ "${FFMPEG_SKIP_DEPLOY:-0}" != "1" ]; then
        mkdir -p "$libs_dir" "$inc_dir"
        # -L 跟随符号链接，落盘为真实文件；只部署**两个**名字：
        #   libX.so        → 构建期链接用（CMake 的 IMPORTED_LOCATION 指向它）
        #   libX.so.<major> → **运行时 SONAME**，动态链接器按 DT_NEEDED 里的这个名字查找
        # 刻意**不**部署 libX.so.<full>（如 libavcodec.so.61.19.100）：它不被任何 DT_NEEDED
        # 引用，只会在 HAP 里再占一份同样大小的副本（两个 ABI 合计约 29 MB），
        # 属于纯粹冗余（依据见 native/third_party/README.md 的 readelf 表）。
        for f in libavformat libavcodec libavutil libswscale libswresample; do
            cp -Lf "$prefix/lib/$f.so" "$libs_dir/$f.so"
            local soname
            soname="$(readelf -d "$prefix/lib/$f.so" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
            if [ -n "$soname" ]; then
                cp -Lf "$prefix/lib/$soname" "$libs_dir/$soname"
            else
                echo "警告：$f.so 没有 SONAME，动态链接器将无法按名字找到它" >&2
            fi
        done
        cp -Rf "$prefix/include/." "$inc_dir/"
        # 记录本次编译的指纹：下次构建只有指纹变化（源码树/本脚本变了）才会重编译
        build_fingerprint "$abi" > "$(stamp_path "$abi")"
        echo "---- 部署完成 ----"
        echo "    库：$libs_dir"
        echo "    头：$inc_dir"
        echo "    指纹：$(stamp_path "$abi")"
    fi
}

case "$ABI_ARG" in
    all) build_abi x86_64; build_abi arm64-v8a ;;
    *)   build_abi "$ABI_ARG" ;;
esac

echo "完成。产物目录：$OUT_ROOT"
