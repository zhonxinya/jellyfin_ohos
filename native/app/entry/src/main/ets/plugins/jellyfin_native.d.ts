declare module 'libjellyfin_native.so' {
  /** 软解逐帧结果：pixels 为 RGBA_8888 ArrayBuffer（ok 为 true 时存在） */
  interface SoftFrameResult {
    ok: boolean;
    width: number;
    height: number;
    ptsSec: number;
    frameIndex: number;
    bytesFetched: number;
    error?: string;
    pixels?: ArrayBuffer;
  }

  interface JellyfinNativeModule {
    getVersion(): string;
    configureServer(serverUrl: string): string;
    setDeviceId(deviceId: string): string;
    login(username: string, password: string): string;
    logout(): string;
    restoreSession(sessionJson: string): string;
    getSession(): string;
    getHome(): string;
    getHomeSection(section: string, limit: number): string;
    getBrowseItems(browseType: string, startIndex: number, limit: number, parentId: string): string;
    queryItems(optionsJson: string): string;
    getGenres(parentId: string, startIndex: number, limit: number): string;
    getStudios(parentId: string, startIndex: number, limit: number): string;
    getSuggestions(parentId: string, limit: number): string;
    getLibraryItems(parentId: string, startIndex: number, limit: number): string;
    search(query: string, startIndex: number, limit: number, parentId: string, includeItemTypes: string): string;
    getItemDetail(itemId: string): string;
    getSeasonEpisodes(seriesId: string, seasonId: string): string;
    getPlaybackInfo(itemId: string, optionsJson: string): string;
    toggleFavorite(itemId: string, favorite: boolean): string;
    togglePlayed(itemId: string, played: boolean): string;
    getUserItemData(itemId: string): string;
    getUserById(userId: string): string;
    /** 当前用户的媒体库视图（`/Users/{id}/Views`）：Id 就是用户配置里 OrderedViews 等字段引用的值 */
    getUserViews(): string;
    /** 只改若干用户配置字段：原生侧 GET 当前配置 → 合并 → POST 完整配置 */
    patchUserConfiguration(patchJson: string): string;
    searchHints(query: string, limit: number, parentId: string, includeItemTypes: string): string;
    getPlaylists(): string;
    createPlaylist(name: string, itemId: string, mediaType: string): string;
    addToPlaylist(playlistId: string, itemId: string): string;
    /** 读取播放列表内容（第 2/3 参数为分页）；返回的条目带 PlaylistItemId（列表条目 id） */
    getPlaylistItems(playlistId: string, startIndex: number, limit: number): string;
    /** 从播放列表移除条目；entryIds 是逗号分隔的 PlaylistItemId（不是媒体 id） */
    removeFromPlaylist(playlistId: string, entryIds: string): string;
    /** 移动列表条目到新下标（0 基） */
    movePlaylistItem(playlistId: string, entryId: string, newIndex: number): string;
    /** 删除播放列表本体 */
    deletePlaylist(playlistId: string): string;
    reportPlaybackProgress(itemId: string, positionTicks: number, isPaused: boolean): string;
    reportPlaybackStopped(itemId: string, positionTicks: number): string;
    playerOpen(itemId: string, optionsJson: string): string;
    softPlayOpen(itemId: string, surfaceId: string, surfaceWidth: number, surfaceHeight: number, renderMode: string, optionsJson: string): string;
    /**
     * 在**当前线程**初始化/复用软解 EGL 渲染器（必须是将来调用 `softPlayRenderLast()`
     * 的那个线程 —— 即 ArkTS 的 UI 线程）。
     *
     * 为什么必须是同步接口：EGL/DGLES 把"当前上下文 / 当前 surface"记在**线程私有**状态里，
     * 初始化与渲染必须同线程。历史实现把初始化放在 `softPlayOpen`（`RunAsync` 工作线程）里，
     * 于是 UI 线程逐帧 `eglSwapBuffers` 全部失败：驱动日志 `EGL_BAD_SURFACE, g_handle is null`
     * （0x300d），**帧在涨、屏幕全黑、上层无任何报错** —— 即"软解黑屏"。
     *
     * 调用时机：`softPlayOpen` 成功之后、启动帧循环之前。
     * 返回 JSON：`{ ok, data: { renderReady, renderReused, renderWidth, renderHeight,
     *             renderError?, xcomponentSize?, renderThreadId, surfaceGeneration } }`
     */
    softPlayInitRenderer(surfaceId: string, width: number, height: number, renderMode: string): string;
    /**
     * 取下一帧（解码 + EGL 渲染）。
     *
     * **异步**：该路径未命中缓存时会做同步 HTTP，必须放在工作线程执行，
     * 否则会阻塞 UI 线程触发 appfreeze（设备实测）。返回 JSON：
     * `{ ok, data: { ok, width, height, ptsSec, frameIndex, bytesFetched, rendered, error?, renderError? } }`
     */
    softPlayNextFrame(maxWidth: number): Promise<string>;
    /**
     * 把最近一帧渲染上屏（EGL）。**必须由 UI 线程调用**：EGL 窗口 surface 的 swap 有线程约束，
     * 在工作线程里 swap 会失败（设备实测 0x12301，帧解出来但上不了屏）。
     * 返回 JSON：`{ ok, data: { rendered, renderError } }`
     */
    softPlayRenderLast(): string;
    softPlayStatus(): string;
    softPlayClose(): string;
    /** 软解会话 seek：跳转到指定时间点（秒），用于续播 */
    softPlaySeek(positionSec: number): string;
    /**
     * 设置软解画面缩放模式（「视频比例」）：
     * 0 适应 / 1 填充 / 2 拉伸 / 3 原始（与 ArkTS 的 PlayerAspectMode 顺序一致）。
     * 与硬解的 `videoScaleType` 不同，这个值由 EglRenderer 自己换算顶点缩放，播放中可随时切换。
     */
    softPlaySetScale(mode: number): string;
    /** 读取 XComponent 视频区域的最新触摸事件（由 DispatchTouchEvent 捕获） */
    getXComponentTouchEvent(): string;
    playerPlay(): string;
    playerPause(): string;
    playerSeek(positionTicks: number): string;
    playerStop(): string;
    playerGetState(): string;
    adminListUsers(): string;
    adminListDevices(): string;
    adminListTasks(): string;
    adminGetSystemInfo(): string;
    adminGenericGet(path: string): string;
    adminGenericPost(path: string, bodyJson: string): string;
    adminGenericPostNoBody(path: string): string;
    adminGenericDelete(path: string): string;
    /**
     * 媒体库管理（设置 → 媒体库）。
     * 请求构造与响应归一化都在 C++ `core/api/library_admin_api.*`，这里只透传参数。
     * 返回 `{ ok, code, message, data }`，`data` 的形状见 `common/LibraryModels.ets`。
     */
    libraryVirtualFolders(): string;
    libraryAvailableOptions(contentType: string, isNewLibrary: boolean): string;
    libraryLocalization(): string;
    /** pathsJson 是字符串数组 JSON，mediaPath 形如 `["/media/movies"]` */
    libraryAddVirtualFolder(name: string, collectionType: string, pathsJson: string,
                            optionsJson: string, refreshLibrary: boolean): string;
    libraryRenameVirtualFolder(name: string, newName: string, refreshLibrary: boolean): string;
    libraryRemoveVirtualFolder(name: string, refreshLibrary: boolean): string;
    libraryAddMediaPath(name: string, path: string, networkPath: string,
                        refreshLibrary: boolean): string;
    /** 改路径，`name` 仍用「库名」，`path` 是**改后**的路径（服务端按名称+路径匹配） */
    libraryUpdateMediaPath(name: string, path: string, networkPath: string): string;
    libraryRemoveMediaPath(name: string, path: string, refreshLibrary: boolean): string;
    libraryUpdateOptions(itemId: string, optionsJson: string): string;
    /** 扫描所有媒体库 */
    libraryScanAll(): string;
    /** 只扫描一个媒体库（媒体库条目本身就是 CollectionFolder，可单独刷新） */
    libraryScanFolder(itemId: string, metadataRefreshMode: string, imageRefreshMode: string,
                      replaceAllMetadata: boolean, replaceAllImages: boolean): string;
    /** 服务器级媒体库设置（显示方式/图片落盘/扫描并发），返回已补齐默认值的完整 ServerConfiguration */
    libraryServerConfig(): string;
    /** 整体替换服务器配置：必须回传 `libraryServerConfig()` 拿到的完整对象 */
    libraryUpdateServerConfig(configJson: string): string;
    /** 条目已有图片列表（ImageInfo[]：ImageType/ImageIndex/Width/Height），用来如实显示封面尺寸 */
    libraryCoverInfo(itemId: string): string;
    /** 由**服务器**去抓取给定 URL 的图片作为封面（`POST /Items/{id}/RemoteImages/Download`） */
    librarySetCoverFromUrl(itemId: string, imageType: string, imageUrl: string): string;
    /** 删除封面；`imageIndex` 传 -1 表示按类型整组删除 */
    libraryDeleteCover(itemId: string, imageType: string, imageIndex: number): string;
    setPreference(key: string, value: string): string;
    getPreferences(): string;
    getImageUrl(itemId: string, imageType: string, maxWidth: number, tag: string): string;
    /** 构造外挂字幕地址（播放中切换字幕）：返回 JSON { ok, data: { url, format, codec, imageSubtitle } } */
    subtitleUrl(itemId: string, mediaSourceId: string, streamIndex: number, codec: string): string;
    setImageCacheDir(dir: string): string;
    setCaBundlePath(path: string): string;
    hasCaBundle(): string;
    loadImage(url: string): string;
    clearImageCache(): string;
  }

  const jellyfinNative: JellyfinNativeModule;
  export default jellyfinNative;
}
