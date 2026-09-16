#ifndef JELLYFIN_NAPI_H
#define JELLYFIN_NAPI_H

#include "napi/native_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Registers all Jellyfin native NAPI exports on the given exports object.
 * Methods return JSON strings shaped as:
 *   {"ok":bool,"code":number,"message":string,"data":...}
 * except getVersion() which returns a plain version string.
 */
napi_value jellyfin_napi_init(napi_env env, napi_value exports);

#ifdef __cplusplus
}
#endif

#endif /* JELLYFIN_NAPI_H */
