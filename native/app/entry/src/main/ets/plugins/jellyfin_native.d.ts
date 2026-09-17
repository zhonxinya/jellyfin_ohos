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
    softPlayNextFrame(maxWidth: number): SoftFrameResult;
    softPlayStatus(): string;
    softPlayClose(): string;
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
