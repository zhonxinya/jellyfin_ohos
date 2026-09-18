#include "version.h"

#include "app_version.h"

extern "C" const char *jellyfin_core_version(void)
{
    // 版本来自 app.json5（经 CMake 注入的 JELLYFIN_APP_VERSION），不再各自写死
    return JELLYFIN_APP_VERSION "-core";
}
