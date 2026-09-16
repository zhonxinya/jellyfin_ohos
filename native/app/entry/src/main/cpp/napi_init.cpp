#include "napi/native_api.h"

#include "jellyfin_napi.h"

static napi_value Init(napi_env env, napi_value exports)
{
    return jellyfin_napi_init(env, exports);
}

static napi_module jellyfinNativeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "jellyfin_native",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterJellyfinNativeModule(void)
{
    napi_module_register(&jellyfinNativeModule);
}
