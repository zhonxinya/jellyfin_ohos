#!/usr/bin/env bash
#
# 为 HarmonyOS/OpenHarmony 交叉编译 **dav1d**（AV1 软件解码器），供 FFmpeg 的
# `libdav1d` 解码器使用（`scripts/build_ffmpeg_ohos.sh` 会 `--enable-libdav1d`）。
#
# 为什么要引入 dav1d（而不是用 FFmpeg 自带的 `av1` 解码器）：
#   FFmpeg 7.1 的 `libavcodec/av1dec.c` 在 `get_pixel_format()` 里有一处硬性判断——
#   只要 `ff_get_format()` 没有真的初始化出硬件加速（`avctx->hwaccel == NULL`），
#   就 `return AVERROR(ENOSYS)`（"Your platform doesn't support hardware accelerated
#   AV1 decoding"）。而本工程的 FFmpeg 是 `--disable-hwaccels` 构建的，
#   `HWACCEL_MAX == 0` 使"软件格式"这一路的绕过分支永远进不去 ——
#   于是自带 av1 解码器**每一包都返回 -38（Function not implemented）**、一帧都解不出来。
#   该结论已用同源码/同 configure 的宿主二进制复现（`avcodec_send_packet` 连续失败、
#   600 包 0 帧），设备上表现为"回退软解后一直黑屏"。
#   dav1d 是独立的 AV1 软件解码器（BSD-2-Clause），多线程（帧级 + 瓦片级），
#   也是 Jellyfin 服务端与各类桌面播放器实际使用的 AV1 解码器。
#
# 源码位置：native/third_party/dav1d/source/（随仓库提交的上游源码，版本见 VERSION 等价物
#           meson.build 的 project(version:)，当前 1.5.1）
# 产物位置（均随仓库提交，克隆后无需重新编译即可构建）：
#   native/app/entry/libs/<abi>/libdav1d.so        共享库（供链接）
#   native/app/entry/libs/<abi>/libdav1d.so.7      运行期 SONAME（动态链接器按此名查找）
#   native/third_party/dav1d/include/             公开头文件
#   native/third_party/dav1d/pkgconfig/<abi>/dav1d.pc  交叉编译用的 pkg-config 描述（供 FFmpeg configure）
#   native/third_party/dav1d/build-stamp-<abi>.txt 本次编译指纹（源码树 + 本脚本）
#
# 设计要点：
# - **共享库**（与 FFmpeg 一致：动态链接便于用户替换，也避免与 FFmpeg 的 LGPL 静态链接冲突）
# - 不构建 tools/tests/examples/doc（只需解码库）
# - **x86_64 关闭汇编**：dav1d 的 x86 汇编需要 nasm，本工程与 CI 环境都没有（FFmpeg 同样
#   `--disable-asm`）；纯 C 的 dav1d 仍是多线程的，比 FFmpeg 自带解码器快得多。
#   **arm64-v8a 打开汇编**：aarch64 的 .S 由 clang 直接汇编，无需 nasm（实测 73 个目标全部编译通过）
# - **不在源码树内构建**：每次把源码复制到临时目录再 meson setup，保证 third_party 下
#   始终是未经改动的上游源码（便于 diff、升级与许可溯源）
#
# 用法：
#   scripts/build_dav1d_ohos.sh [x86_64|arm64-v8a|all] [输出目录]
# 默认输出：<repo 父目录>/_dav1d-build/out/<abi>
#
# 环境变量：
#   DAV1D_FORCE_REBUILD=1   忽略指纹判断，强制重建
#   DAV1D_SKIP_DEPLOY=1     只构建到输出目录，不部署进仓库
#   BUILD_JOBS=N            并行编译任务数（默认 nproc）
#   OHOS_COMMAND_LINE_TOOLS HarmonyOS 命令行工具根目录
set -euo pipefail

ABI_ARG="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="${DAV1D_WORK_ROOT:-$(dirname "$REPO_ROOT")/_dav1d-build}"
OUT_ROOT="${2:-${DAV1D_OUT_ROOT:-$WORK_ROOT/out}}"

SRC_DIR="$REPO_ROOT/native/third_party/dav1d/source"
DAV1D_VERSION="1.5.1"

# ── 定位 HarmonyOS 命令行工具链（与 build_ffmpeg_ohos.sh 同一套探测顺序）──────────
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

die() { echo "错误：$*" >&2; exit 1; }

TOOLS_ROOT="$(find_tools_root || true)"
[ -n "$TOOLS_ROOT" ] || die "找不到 HarmonyOS 命令行工具链（可设 OHOS_COMMAND_LINE_TOOLS 指定其根目录）"
SDK_NATIVE="$TOOLS_ROOT/sdk/default/openharmony/native"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
SYSROOT="$SDK_NATIVE/sysroot"
[ -d "$LLVM_BIN" ] || die "找不到 OHOS LLVM 工具链：$LLVM_BIN"
[ -d "$SYSROOT" ] || die "找不到 OHOS sysroot：$SYSROOT"

# meson/ninja：不装进系统（本机的 Python 可能受 PEP 668 保护），优先用 PATH，其次 ~/.local/bin
MESON_BIN="${MESON_BIN:-$(command -v meson || true)}"
if [ -z "$MESON_BIN" ] && [ -x "$HOME/.local/bin/meson" ]; then MESON_BIN="$HOME/.local/bin/meson"; fi
[ -n "$MESON_BIN" ] || die "找不到 meson（dav1d 用 meson 构建）：pip3 install --user meson"
command -v ninja >/dev/null 2>&1 || die "找不到 ninja：dnf/apt install ninja-build"

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# ── 源码完整性检查 ────────────────────────────────────────────────────────────
[ -f "$SRC_DIR/meson.build" ] || die "找不到内置 dav1d 源码：$SRC_DIR"
[ -d "$SRC_DIR/src" ] || die "dav1d 源码树不完整：缺少 src/"
[ -d "$SRC_DIR/include/dav1d" ] || die "dav1d 源码树不完整：缺少 include/dav1d/"
ver_in_tree="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" "$SRC_DIR/meson.build" | head -n1)"
[ "$ver_in_tree" = "$DAV1D_VERSION" ] \
    || die "内置 dav1d 版本与预期不符：期望 $DAV1D_VERSION，实际 ${ver_in_tree:-未知}"
echo "源码：$SRC_DIR（dav1d $DAV1D_VERSION，$(find "$SRC_DIR" -type f | wc -l) 个文件）"

# ── 是否需要重建（与 FFmpeg 脚本同一套指纹思路，见 native/third_party/README.md）──
stamp_path() { printf '%s/build-stamp-%s.txt' "$REPO_ROOT/native/third_party/dav1d" "$1"; }

source_tree_id() {
    git -C "$REPO_ROOT" rev-parse --verify --quiet "HEAD:native/third_party/dav1d/source" 2>/dev/null \
        || echo nogit
}

source_tree_dirty() {
    [ "$(source_tree_id)" = "nogit" ] && return 1
    [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- \
             native/third_party/dav1d/source 2>/dev/null)" ]
}

build_fingerprint() {
    local abi="$1"
    printf 'abi=%s\ndav1d=%s\nscript_sha256=%s\nsource_tree=%s\n' \
        "$abi" "$DAV1D_VERSION" \
        "$(sha256sum "$SCRIPT_DIR/build_dav1d_ohos.sh" | awk '{print $1}')" \
        "$(source_tree_id)"
}

needs_build() {
    local abi="$1" deployed_lib="$2" stamp
    [ "${DAV1D_FORCE_REBUILD:-0}" = "1" ] && return 0
    [ -f "$deployed_lib" ] || return 0
    if [ "$(source_tree_id)" != "nogit" ]; then
        source_tree_dirty && return 0
        stamp="$(stamp_path "$abi")"
        [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(build_fingerprint "$abi")" ] && return 1
        return 0
    fi
    if [ -n "$(find "$SRC_DIR" "$SCRIPT_DIR/build_dav1d_ohos.sh" -newer "$deployed_lib" -print -quit 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# 每个 ABI 的交叉文件：CPU 族、sysroot、以及（x86_64 特有的）关闭汇编
write_cross_file() {
    local abi="$1" file="$2" cc ar strip sysroot_lib march enable_asm
    case "$abi" in
        x86_64)
            cc="$LLVM_BIN/x86_64-unknown-linux-ohos-clang"; sysroot_lib="$SYSROOT/usr/lib/x86_64-linux-ohos"
            march=""; enable_asm=false ;;
        arm64-v8a)
            cc="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"; sysroot_lib="$SYSROOT/usr/lib/aarch64-linux-ohos"
            march="-march=armv8-a"; enable_asm=true ;;
        *) die "不支持的 ABI：$abi（仅支持 x86_64 / arm64-v8a）" ;;
    esac
    ar="$LLVM_BIN/llvm-ar"; strip="$LLVM_BIN/llvm-strip"
    local cpu_family
    case "$abi" in x86_64) cpu_family=x86_64 ;; *) cpu_family=aarch64 ;; esac

    cat > "$file" <<EOF
# 由 scripts/build_dav1d_ohos.sh 生成（$abi）；交叉编译 dav1d 到 HarmonyOS/OpenHarmony
[binaries]
c = '$cc'
ar = '$ar'
strip = '$strip'

[host_machine]
system = 'linux'
cpu_family = '$cpu_family'
cpu = '${march#-march=}'
endian = 'little'

[properties]
# 交叉目标无法在构建机上运行：meson 的相关自检退化为"编译通过即认为可用"
needs_exe_wrapper = true
c_args = ['--sysroot=$SYSROOT', '$march', '-fPIC', '-O2']
c_link_args = ['--sysroot=$SYSROOT', '-L$sysroot_lib', '-Wl,-rpath-link,$sysroot_lib']
EOF
    ENABLE_ASM="$enable_asm"
}

# 生成给 FFmpeg configure 用的 dav1d.pc（路径指向**部署到仓库里的**库与头文件，
# 这样 FFmpeg 的交叉编译不必依赖本次的临时 prefix）。
# **每个 ABI 一份**（pkgconfig/<abi>/dav1d.pc）：libdir 必须指向该 ABI 的库目录，
# 否则给 arm64 编 FFmpeg 时会链接到 x86_64 的 dav1d。
write_pc_file() {
    local out="$1" abi="$2" inc_dir="$REPO_ROOT/native/third_party/dav1d/include"
    local lib_dir="$REPO_ROOT/native/app/entry/libs/$abi"
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<EOF
prefix=$REPO_ROOT/native/third_party/dav1d
includedir=$inc_dir
libdir=$lib_dir

Name: libdav1d
Description: AV1 decoding library (HarmonyOS cross build, $abi)
Version: $DAV1D_VERSION
Libs: -L\${libdir} -ldav1d
Libs.private: -pthread
Cflags: -I\${includedir}
EOF
}

build_abi() {
    local abi="$1"
    local work="$OUT_ROOT/work-$abi"
    local prefix="$OUT_ROOT/$abi"
    local libs_dir="$REPO_ROOT/native/app/entry/libs/$abi"
    local inc_dir="$REPO_ROOT/native/third_party/dav1d/include"
    local cross_file="$OUT_ROOT/cross-$abi.txt"

    if [ "${DAV1D_SKIP_DEPLOY:-0}" != "1" ] && ! needs_build "$abi" "$libs_dir/libdav1d.so"; then
        echo "==================== 跳过 $abi（指纹一致，产物已是最新） ===================="
        return 0
    fi

    echo "==================== 构建 dav1d $abi ===================="
    rm -rf "$work" "$prefix"
    mkdir -p "$work" "$prefix"
    cp -a "$SRC_DIR/." "$work/"
    mkdir -p "$OUT_ROOT"
    write_cross_file "$abi" "$cross_file"

    local asm_opt="$ENABLE_ASM"
    PATH="$(dirname "$MESON_BIN"):$PATH" "$MESON_BIN" setup "$work/build" "$work" \
        --cross-file "$cross_file" \
        --prefix="$prefix" \
        --buildtype=release \
        -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false \
        -Denable_asm="$asm_opt" \
        > "$OUT_ROOT/meson-setup-$abi.log" 2>&1 \
        || { tail -30 "$OUT_ROOT/meson-setup-$abi.log"; die "meson setup 失败（$abi），日志：$OUT_ROOT/meson-setup-$abi.log"; }

    ninja -C "$work/build" -j"$BUILD_JOBS" > "$OUT_ROOT/ninja-$abi.log" 2>&1 \
        || { tail -30 "$OUT_ROOT/ninja-$abi.log"; die "ninja 失败（$abi），日志：$OUT_ROOT/ninja-$abi.log"; }
    ninja -C "$work/build" install > "$OUT_ROOT/install-$abi.log" 2>&1 \
        || { tail -20 "$OUT_ROOT/install-$abi.log"; die "ninja install 失败（$abi）"; }

    echo "---- $abi 产物 ----"
    ls -1 "$prefix/lib" | sed 's/^/    /'

    if [ "${DAV1D_SKIP_DEPLOY:-0}" != "1" ]; then
        mkdir -p "$libs_dir" "$inc_dir"
        # 与 FFmpeg 库同一约定：同时部署 **两个** 名字
        #   libdav1d.so     → 构建期链接用（-ldav1d）
        #   libdav1d.so.7   → 运行期 SONAME（libavcodec.so 的 DT_NEEDED 指向它）
        # HAP 打包不保留符号链接，所以两个名字都必须是真实文件（见 third_party/README.md）。
        cp -Lf "$prefix/lib/libdav1d.so" "$libs_dir/libdav1d.so"
        local soname
        soname="$(readelf -d "$prefix/lib/libdav1d.so" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
        if [ -n "$soname" ]; then
            cp -Lf "$prefix/lib/$soname" "$libs_dir/$soname"
        else
            echo "警告：libdav1d.so 没有 SONAME，动态链接器将无法按名字找到它" >&2
        fi
        cp -Rf "$prefix/include/." "$inc_dir/"
        write_pc_file "$REPO_ROOT/native/third_party/dav1d/pkgconfig/$abi/dav1d.pc" "$abi"
        build_fingerprint "$abi" > "$(stamp_path "$abi")"
        echo "---- 部署完成 ----"
        echo "    库：$libs_dir/libdav1d.so（$(stat -c%s "$libs_dir/libdav1d.so") 字节）"
        echo "    头：$inc_dir"
        echo "    指纹：$(stamp_path "$abi")"
    fi
}

case "$ABI_ARG" in
    all) build_abi x86_64; build_abi arm64-v8a ;;
    *)   build_abi "$ABI_ARG" ;;
esac

echo "完成。产物目录：$OUT_ROOT"
