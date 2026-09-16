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
    search(query: string, startIndex: number, limit: number): string;
    getItemDetail(itemId: string): string;
    getSeasonEpisodes(seriesId: string, seasonId: string): string;
    getPlaybackInfo(itemId: string, optionsJson: string): string;
    toggleFavorite(itemId: string, favorite: boolean): string;
    togglePlayed(itemId: string, played: boolean): string;
    getUserItemData(itemId: string): string;
    getUserById(userId: string): string;
    updateUserConfiguration(configurationJson: string): string;
    searchHints(query: string, limit: number): string;
    getPlaylists(): string;
    createPlaylist(name: string, itemId: string): string;
    addToPlaylist(playlistId: string, itemId: string): string;
    reportPlaybackProgress(itemId: string, positionTicks: number, isPaused: boolean): string;
    reportPlaybackStopped(itemId: string, positionTicks: number): string;
    playerOpen(itemId: string, optionsJson: string): string;
    playerSoftDecodeProbe(itemId: string, cacheDir: string, optionsJson: string): string;
    softPlayOpen(itemId: string, surfaceId: string, surfaceWidth: number, surfaceHeight: number, optionsJson: string): string;
    softPlayNextFrame(maxWidth: number): SoftFrameResult;
    softPlayStatus(): string;
    softPlayClose(): string;
    softPlayDumpFrame(path: string): string;
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
    setImageCacheDir(dir: string): string;
    setCaBundlePath(path: string): string;
    hasCaBundle(): string;
    loadImage(url: string): string;
    clearImageCache(): string;
  }

  const jellyfinNative: JellyfinNativeModule;
  export default jellyfinNative;
}
