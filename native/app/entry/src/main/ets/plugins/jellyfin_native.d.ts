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
    updateUserConfiguration(configurationJson: string): string;
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
    playerSoftDecodeProbe(itemId: string, cacheDir: string, optionsJson: string): string;
    softPlayOpen(itemId: string, surfaceId: string, surfaceWidth: number, surfaceHeight: number, renderMode: string, optionsJson: string): string;
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
    softPlayDumpFrame(path: string): string;
    softPlaySelfTest(): string;
    renderTargetProbe(surfaceId: string, width: number, height: number, renderMode: string): string;
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
