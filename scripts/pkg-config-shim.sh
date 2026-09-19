#!/usr/bin/env bash
# 极简 pkg-config 替身：只解析 PKG_CONFIG_PATH / PKG_CONFIG_LIBDIR 下的 .pc 文件，
# 回答 FFmpeg configure 会问的问题（--exists / --modversion / --cflags / --libs / --variable）。
#
# 为什么需要它：HarmonyOS 命令行工具链里没有 pkg-config（本机也没有 pkgconf，且无法安装），
# 而 FFmpeg 的 `--enable-libdav1d` 走的是 `require_pkg_config`，必须有一个能应答的
# pkg-config 程序。这里用一段 bash 顶上，避免为一个查询引入额外的系统依赖。
#
# 用法与真正的 pkg-config 相同（只实现交叉编译配置期真正用得到的那几种查询）：
#   --exists  --print-errors  --modversion  --cflags  --libs
#   --atleast-version=X  --exact-version=X  --variable=<name>  --static
set -uo pipefail

search_path="${PKG_CONFIG_PATH:-}"
search_path="${search_path}${search_path:+:}${PKG_CONFIG_LIBDIR:-}"
sysroot="${PKG_CONFIG_SYSROOT_DIR:-}"

want_exists=0
want_modversion=0
want_cflags=0
want_libs=0
want_var=""
atleast=""
exact=""
packages=()
pending_op=""

for arg in "$@"; do
    case "$arg" in
        --exists) want_exists=1 ;;
        --print-errors|--silence-errors|--short-errors|--static|--debug) ;;
        --cflags|--cflags-only-I|--cflags-only-other) want_cflags=1 ;;
        --libs|--libs-only-l|--libs-only-L|--libs-only-other) want_libs=1 ;;
        --modversion) want_modversion=1 ;;
        --variable=*) want_var="${arg#--variable=}" ;;
        --atleast-version=*|--atleast-pkgconfig-version=*) atleast="${arg#*=}" ;;
        --exact-version=*) exact="${arg#*=}" ;;
        --*) ;;                       # 其它开关一律忽略
        # FFmpeg 的 `require_pkg_config libdav1d "dav1d >= 0.5.0" ...` 会把版本约束
        # 拆成三个参数（dav1d / >= / 0.5.0）传进来，这里按 pkg-config 的语法吸收掉
        ">="|"="|">"|"<="|"<") pending_op="$arg" ;;
        *)
            if [ -n "$pending_op" ]; then
                case "$pending_op" in
                    ">="|"=") atleast="$arg" ;;
                    ">"|"<"|"<=") ;;   # 极少用；不阻断配置，交给编译期验证
                esac
                pending_op=""
            else
                packages+=("$arg")
            fi
            ;;
    esac
done

find_pc() {
    local name="$1" dir
    local IFS=':'
    for dir in $search_path; do
        [ -n "$dir" ] || continue
        if [ -f "$dir/$name.pc" ]; then printf '%s\n' "$dir/$name.pc"; return 0; fi
    done
    return 1
}

# .pc 的两种写法都要支持：变量用 `key = value`，字段用 `Key: value`（dav1d.pc 用后者）
field_of() {
    local file="$1" key="$2"
    sed -n "s/^${key}[[:space:]]*:[[:space:]]*//p" "$file" | head -n1
}

var_of() {
    local file="$1" key="$2"
    sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -n1
}

# ${prefix} / ${includedir} / ${libdir} / ${pcfiledir} 必须展开
# （meson 生成的 dav1d.pc 就是 `${prefix}/include` 这种写法）
expand_vars() {
    local file="$1" text="$2" name val
    # 变量之间会互相引用（includedir = ${prefix}/include），因此要反复展开到不动点
    local round=0 changed=1
    while [ "$changed" = 1 ] && [ "$round" -lt 10 ]; do
        changed=0
        for name in prefix exec_prefix includedir libdir pcfiledir datarootdir; do
            if [[ "$text" == *'${'"$name"'}'* ]]; then
                if [ "$name" = "pcfiledir" ]; then val="$(dirname "$file")"; else val="$(var_of "$file" "$name")"; fi
                [ -n "$val" ] || val="/"
                text="${text//\$\{$name\}/$val}"
                changed=1
            fi
        done
        round=$((round + 1))
    done
    printf '%s' "$text"
}

# 版本比较：按点分段（sort -V 足够处理 1.5.1 / 1.5 / 0.9.2 这类版本号）
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

status=0
cflags_out=""
libs_out=""
modversion_out=""

for name in "${packages[@]}"; do
    if ! pc="$(find_pc "$name")"; then
        [ "$want_exists" = 1 ] && echo "Package $name was not found in the pkg-config search path." >&2
        status=1
        continue
    fi
    ver="$(field_of "$pc" Version)"
    if [ -n "$atleast" ] && ! version_ge "$ver" "$atleast"; then status=1; fi
    if [ -n "$exact" ] && [ "$ver" != "$exact" ]; then status=1; fi

    if [ -n "$want_var" ]; then
        if [ "$want_var" = "pcfiledir" ]; then
            printf '%s\n' "$(dirname "$pc")"
        else
            printf '%s\n' "$(expand_vars "$pc" "$(var_of "$pc" "$want_var")")"
        fi
        continue
    fi
    [ "$want_modversion" = 1 ] && modversion_out="$ver"

    cflags="$(expand_vars "$pc" "$(field_of "$pc" Cflags) $(field_of "$pc" Cflags.private)")"
    libs="$(expand_vars "$pc" "$(field_of "$pc" Libs) $(field_of "$pc" Libs.private)")"
    if [ -n "$sysroot" ]; then
        # 交叉编译：把 -I/-L 指向 sysroot 内的同一路径（与真 pkg-config 行为一致）
        cflags="$(printf '%s' "$cflags" | sed "s#\(^\| \)-I#\1-I$sysroot#g")"
        libs="$(printf '%s' "$libs" | sed "s#\(^\| \)-L#\1-L$sysroot#g")"
    fi
    cflags_out="$cflags_out $cflags"
    libs_out="$libs_out $libs"
done

# --exists 单独使用时只返回状态码，不打印任何东西
if [ "$want_exists" = 1 ] && [ "$want_cflags" = 0 ] && [ "$want_libs" = 0 ] \
   && [ "$want_modversion" = 0 ] && [ -z "$want_var" ] && [ -z "$atleast" ] && [ -z "$exact" ]; then
    exit "$status"
fi

[ "$want_modversion" = 1 ] && printf '%s\n' "$modversion_out"
if [ "$want_cflags" = 1 ]; then printf '%s\n' "$(printf '%s' "$cflags_out" | sed 's/^ *//')"; fi
if [ "$want_libs" = 1 ]; then printf '%s\n' "$(printf '%s' "$libs_out" | sed 's/^ *//')"; fi
exit "$status"
