#ifndef JELLYFIN_CORE_APP_VERSION_H
#define JELLYFIN_CORE_APP_VERSION_H

/*
 * 应用版本号的单一来源。
 *
 * 真正的值来自 `native/app/AppScope/app.json5` 的 `versionName`：CMake 在配置期读出来，
 * 以编译宏 `JELLYFIN_APP_VERSION="x.y.z"` 注入（见 native/app/entry/src/main/cpp/CMakeLists.txt）。
 * 下面的 `#ifndef` 回退值只服务于**不经 CMake 的宿主单测**（scripts/force-build.ps1 直接
 * 用 g++ 编译 native/core 的源码），保证它们仍能编过而不是报宏未定义。
 *
 * 为什么要有这个头：曾经 app.json5 已是 1.0.0，而 core / napi / player 与 User-Agent
 * 各自还写着 0.1.0，Jellyfin 服务端仪表盘与 Sessions 里看到的应用版本因此互相矛盾。
 * 版本只在 app.json5 里改一次，其余位置一律引用本宏。
 */

#ifndef JELLYFIN_APP_VERSION
#define JELLYFIN_APP_VERSION "1.0.0"
#endif

#endif /* JELLYFIN_CORE_APP_VERSION_H */
