#ifndef JELLYFIN_CORE_API_OPTIONS_PARSE_H
#define JELLYFIN_CORE_API_OPTIONS_PARSE_H

#include "items_query.h"
#include "playback_api.h"

#include <nlohmann/json.hpp>

namespace jellyfin {
namespace api {

/**
 * 宿主（NAPI）传入的 JSON 选项 → API 结构体的解析（**容错**，见 `json_arg.h`）。
 *
 * ## 为什么单独成文件而不是塞进各自的 api 文件
 *
 * 这两个函数是**纯数据变换**，不碰网络客户端。放进 `items_query.cpp` / `playback_api.cpp`
 * 后，主机单测为了编译它们就得链接 `api_client.cpp`（进而 `http_client.cpp`），
 * 单测的编译依赖被无谓扩大。独立文件后单测只链接它自己。
 *
 * ## 为什么不能用 `j.value(key, default)`
 *
 * `nlohmann::json::value()` **只在键不存在**时返回默认值；键存在但类型不符会抛
 * `type_error.302`。而在 NAPI 边界上"类型不符"是常态：ArkTS 的 `JSON.stringify()`
 * 会把对象字段里的 `null` 原样保留、把 `undefined` 省略（前端漏写一个字段就是一次
 * 未捕获异常），JS 大整数会退化成字符串。异常一旦从 `RunAsync` 的 worker 线程逸出，
 * libuv 由 C 编写、不会捕获 C++ 异常，`std::terminate()` 会直接终止应用
 * （本机已用最小探针复现）。
 *
 * 这两个函数原本就在 UI 线程的**同步**路径上被调用（`QueryItems` / `GetPlaybackInfo`
 * 等在 `RunAsync` **之前**解析参数），因此"不抛异常"是硬约束，不是偏好。
 *
 * 数值字段经 `json_arg::Int32()` 读取：先判界再窄化，越界回落默认值而不是回绕
 * （回绕后的负 `limit`、或从大正数变成 `-1` 的 `audioStreamIndex` 都是"合法但错误"的值）。
 */

/**
 * 把宿主 JSON 解析成 `ItemsQuery`。
 *
 * 未识别/类型不符的字段一律回落到 `ItemsQuery` 自身的默认值；
 * 顶层不是对象时返回默认构造的查询。
 */
ItemsQuery ParseItemsQueryJson(const nlohmann::json &j);

/**
 * 把宿主 JSON 解析成 `PlaybackInfoOptions`。
 *
 * 未识别/类型不符的字段一律回落到 `PlaybackInfoOptions` 自身的默认值；
 * 顶层不是对象时返回默认构造的选项。
 */
PlaybackInfoOptions ParsePlaybackOptionsJson(const nlohmann::json &j);

} // namespace api
} // namespace jellyfin

#endif /* JELLYFIN_CORE_API_OPTIONS_PARSE_H */
