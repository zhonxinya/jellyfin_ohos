#!/usr/bin/env bash
#
# 校验 HAP 里**真的带着可用的 FFmpeg**（发布门禁）。
#
# 背景：本项目用 FFmpeg 做软解码（系统 AVPlayer 硬解失败时的回落路径）。一旦 FFmpeg
# 没被打进 HAP，功能会在真机上"静默降级"——应用照常启动、照常播放硬解成功的片子，
# 只有遇到 HEVC 等硬解失败的媒体时才露出问题。这种"能装能跑但少了半个引擎"的产物
# 不该发出去，所以在发布流程里用本脚本卡住。
#
# 检查内容：
#   1) 期望的每个 ABI 下都有 libjellyfin_native.so；
#   2) 它的 DT_NEEDED 里所有 libav*/libsw* 依赖，都能在同一个 ABI 目录里找到同名文件
#      （动态链接器按 DT_NEEDED 的**精确名字**查找，例如 libavcodec.so.61，
#        少一个名字就等于运行期加载失败）；
#   3) 每个 libav*/libsw* 的 ELF 机器字与该 ABI 相符（arm64-v8a ⇒ AArch64，x86_64 ⇒ X86-64）；
#   4) 不该出现的 ABI 目录不存在（发布用的 arm64 精简包不得夹带 x86_64 载荷）。
#
# 用法：
#   scripts/verify_hap_ffmpeg.sh <hap 路径> <期望的 ABI> [更多 ABI...]
# 例：
#   scripts/verify_hap_ffmpeg.sh dist/app-1.0.0-arm64-v8a-unsigned.hap arm64-v8a
#   scripts/verify_hap_ffmpeg.sh dist/app-1.0.0-universal-unsigned.hap arm64-v8a x86_64
#
# 退出码：0 = 全部通过；1 = 有检查项失败（在 CI 上输出 ::error:: 便于定位）。
set -euo pipefail

HAP="${1:-}"
[ -n "$HAP" ] || { echo "用法：$0 <hap 路径> <期望的 ABI> [更多 ABI...]" >&2; exit 2; }
shift

[ -f "$HAP" ] || { echo "::error::HAP 不存在：$HAP" >&2; exit 1; }
[ "$#" -ge 1 ] || { echo "用法：$0 <hap 路径> <期望的 ABI> [更多 ABI...]" >&2; exit 2; }
EXPECTED_ABIS=("$@")

READELF="${READELF:-readelf}"
UNZIP="${UNZIP:-unzip}"
FFMPEG_LIBS=(libavformat libavcodec libavutil libswscale libswresample)
# AV1 软解依赖的 dav1d（libavcodec 的 DT_NEEDED 里有 libdav1d.so.7）。
# 少了它，AV1 内容会在设备上"回退软解后一直黑屏"——同样是"能装能跑但少了半个引擎"。
DAV1D_LIB=libdav1d

fail=0
note() { printf '    %s\n' "$*"; }
err()  { printf '::error::%s\n' "$*"; fail=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 校验 HAP：$HAP（$(stat -c%s "$HAP" 2>/dev/null || stat -f%z "$HAP") 字节）"
"$UNZIP" -l "$HAP" > "$WORK/list.txt"

# HAP 里实际存在哪些 ABI 目录
mapfile -t PRESENT_ABIS < <(sed -n 's|.*[[:space:]]libs/\([^/]*\)/.*|\1|p' "$WORK/list.txt" | sort -u)

echo "--- 包内 ABI 目录：${PRESENT_ABIS[*]:-（无）}"
for abi in "${PRESENT_ABIS[@]}"; do
    want=0
    for e in "${EXPECTED_ABIS[@]}"; do [ "$e" = "$abi" ] && want=1; done
    if [ "$want" -eq 0 ]; then
        err "出现了不该有的 ABI 载荷：libs/$abi/（期望只有 ${EXPECTED_ABIS[*]}）"
    fi
done

# 解出需要的文件，便于 readelf 检查
mkdir -p "$WORK/x"
for abi in "${EXPECTED_ABIS[@]}"; do
    "$UNZIP" -q -o "$HAP" "libs/$abi/*" -d "$WORK/x" >/dev/null 2>&1 || true
done

for abi in "${EXPECTED_ABIS[@]}"; do
    dir="$WORK/x/libs/$abi"
    echo "--- ABI：$abi"
    if [ ! -f "$dir/libjellyfin_native.so" ]; then
        err "libs/$abi/libjellyfin_native.so 缺失（该 ABI 的 native 代码没打进包）"
        continue
    fi

    case "$abi" in
        arm64-v8a|armeabi-v7a) expect_machine="AArch64" ;;
        x86_64)                expect_machine="X86-64" ;;
        *)                     expect_machine="" ;;
    esac

    # 1) 五个 FFmpeg 库的 SONAME 名字都在
    for f in "${FFMPEG_LIBS[@]}"; do
        soname="$("$READELF" -d "$dir/libjellyfin_native.so" 2>/dev/null \
                  | sed -n "s/.*NEEDED.*\[\($f\.so\.[0-9]*\)\]/\1/p" | head -n1)"
        [ -n "$soname" ] || soname="$f.so"
        if [ ! -f "$dir/$soname" ]; then
            err "libs/$abi/$soname 缺失（$f 没打进 HAP）"
            continue
        fi
        size=$(stat -c%s "$dir/$soname" 2>/dev/null || stat -f%z "$dir/$soname")
        note "$(printf '%-28s %10s 字节' "$soname" "$size")"
    done

    # 1b) libdav1d：libavcodec 需要它（精确 SONAME），缺了 AV1 直接黑屏
    dav1d_soname="$("$READELF" -d "$dir/libavcodec.so" 2>/dev/null \
                   | sed -n 's/.*NEEDED.*\[\(libdav1d\.so\.[0-9]*\)\]/\1/p' | head -n1)"
    if [ -z "$dav1d_soname" ]; then
        err "libs/$abi/libavcodec.so 没有链接 libdav1d（本构建的 AV1 软解解不出帧，见"
        err "  native/third_party/dav1d 与 scripts/build_dav1d_ohos.sh —— 需要 --enable-libdav1d 重编 FFmpeg）"
    elif [ ! -f "$dir/$dav1d_soname" ]; then
        err "libs/$abi/$dav1d_soname 缺失（libavcodec 需要它，运行期加载会失败）"
    else
        note "$(printf '%-28s %10s 字节' "$dav1d_soname" "$(stat -c%s "$dir/$dav1d_soname" 2>/dev/null || stat -f%z "$dir/$dav1d_soname")")"
    fi

    # 2) DT_NEEDED 依赖闭包：libav*/libsw* 必须都能在包内找到
    for so in "$dir"/lib*.so*; do
        [ -f "$so" ] || continue
        base="$(basename "$so")"
        ! "$READELF" -d "$so" 2>/dev/null | grep -q 'NEEDED' && continue
        while read -r needed; do
            [ -n "$needed" ] || continue
            case "$needed" in
                libav*|libsw*|libdav1d*|libc++_shared.so)
                    if [ ! -f "$dir/$needed" ]; then
                        err "$base 需要 $needed，但 libs/$abi/ 里没有（运行期加载会失败）"
                    fi ;;
            esac
        done < <("$READELF" -d "$so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
    done

    # 3) 架构自检：库的机器字必须与 ABI 相符
    if [ -n "$expect_machine" ]; then
        for so in "$dir"/libav*.so "$dir"/libav*.so.* "$dir"/libdav1d.so "$dir"/libdav1d.so.*; do
            [ -f "$so" ] || continue
            machine="$("$READELF" -h "$so" 2>/dev/null | sed -n 's/^ *Machine: *//p' | head -n1)"
            case "$machine" in
                *"$expect_machine"*) : ;;
                *) err "$(basename "$so") 的 ELF 机器字是「${machine:-未知}」，与 ABI $abi 不符" ;;
            esac
        done
        note "（架构自检：libav*/libdav1d 均为 $expect_machine）"
    fi

    # 4) 顺带证明 native 库确实链接了 FFmpeg（JELLYFIN_HAS_FFMPEG 生效）
    if ! "$READELF" -d "$dir/libjellyfin_native.so" 2>/dev/null | grep -q 'NEEDED.*libavcodec'; then
        err "libjellyfin_native.so 没有链接 libavcodec（本构建可能未启用 FFmpeg 软解码）"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "==> 校验失败：该 HAP 不能作为发布产物（见上方 ::error:: 行）"
    exit 1
fi
echo "==> 校验通过：FFmpeg 依赖闭包在包内完整（ABI：${EXPECTED_ABIS[*]}）"
