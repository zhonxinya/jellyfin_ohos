#ifndef JELLYFIN_CORE_IMAGE_CACHE_HTTP_H
#define JELLYFIN_CORE_IMAGE_CACHE_HTTP_H

namespace jellyfin {

/**
 * 安装基于 core `HttpClient` 的图片下载实现（实现在 `image_cache_http.cpp`）。
 *
 * 为什么单独一个文件：`ImageCache` 只依赖注入的下载函数（`ImageDownloadFn`），
 * 因此**不依赖任何 HTTP/TLS 实现**，主机单测不必把 mbedTLS 与网络栈拖进编译
 * （与 `feature/player` 的 `SetRangeFetcher` 同一模式）。
 *
 * 宿主**必须**在 NAPI 初始化时调用本函数；否则取图会明确失败
 * （`getOrDownload()` 返回 `"image downloader not installed"`，不会静默返回空路径）。
 */
void InstallHttpImageDownloader();

} // namespace jellyfin

#endif /* JELLYFIN_CORE_IMAGE_CACHE_HTTP_H */
