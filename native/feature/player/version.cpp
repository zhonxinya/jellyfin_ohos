#include "version.h"

/*
 * feature/player 设计上可整目录移植到其它工程（见本目录 README），
 * 因此这里不引用 native/core 的头文件，只保留一个与 app.json5 同值的回退宏；
 * 本工程构建时由 CMake 注入的 JELLYFIN_APP_VERSION 覆盖它。
 */
#ifndef JELLYFIN_APP_VERSION
#define JELLYFIN_APP_VERSION "1.0.0"
#endif

extern "C" const char *jellyfin_player_version(void)
{
    return JELLYFIN_APP_VERSION "-player";
}
