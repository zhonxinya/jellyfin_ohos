import hilog from '@ohos.hilog';
import jellyfinNative from 'libjellyfin_native.so';
import { JsonUtil } from '../common/JsonUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'JellyfinNative';

/**
 * Parsed bridge result envelope.
 */
export interface NativeResult {
  ok: boolean;
  code: number;
  message: string;
  data: ESObject | null;
}

/**
 * ArkTS wrapper for the jellyfin_native NAPI module (libjellyfin_native.so).
 */
export class JellyfinNative {
  static parseResult(json: string): NativeResult {
    const fallback: NativeResult = {
      ok: false,
      code: -1,
      message: 'invalid response',
      data: null
    };
    if (json === undefined || json === null || json.length === 0) {
      return fallback;
    }
    const obj: ESObject | null = JsonUtil.parseObject(json);
    if (obj === null) {
      return {
        ok: false,
        code: -1,
        message: json,
        data: null
      };
    }
    const ok: boolean = JsonUtil.getBoolean(obj, 'ok', false);
    const code: number = JsonUtil.getNumber(obj, 'code', ok ? 0 : -1);
    const message: string = JsonUtil.getString(obj, 'message', '');
    const data: ESObject | null = JsonUtil.getObject(obj, 'data');
    const result: NativeResult = {
      ok: ok,
      code: code,
      message: message,
      data: data
    };
    return result;
  }

  private static fail(label: string, error: Error): string {
    let msg: string = 'unknown';
    if (error !== undefined && error !== null) {
      msg = `${error}`;
    }
    hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}s', label, msg);
    return JSON.stringify({
      ok: false,
      code: -1,
      message: `${label} unavailable`,
      data: null
    });
  }

  static getVersion(): string {
    try {
      return jellyfinNative.getVersion();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getVersion unavailable');
      return 'unavailable';
    }
  }

  static async configureServer(serverUrl: string): Promise<string> {
    try {
      return await jellyfinNative.configureServer(serverUrl);
    } catch (error) {
      return JellyfinNative.fail('configureServer', error);
    }
  }

  /** 注入按安装持久化的稳定设备标识（应在登录之前调用，避免服务端堆积重复设备） */
  static async setDeviceId(deviceId: string): Promise<string> {
    try {
      return await jellyfinNative.setDeviceId(deviceId);
    } catch (error) {
      return JellyfinNative.fail('setDeviceId', error);
    }
  }

  static async login(username: string, password: string): Promise<string> {
    try {
      return await jellyfinNative.login(username, password);
    } catch (error) {
      return JellyfinNative.fail('login', error);
    }
  }

  static logout(): string {
    try {
      return jellyfinNative.logout();
    } catch (error) {
      return JellyfinNative.fail('logout', error);
    }
  }

  static restoreSession(sessionJson: string): string {
    try {
      return jellyfinNative.restoreSession(sessionJson);
    } catch (error) {
      return JellyfinNative.fail('restoreSession', error);
    }
  }

  static getSession(): string {
    try {
      return jellyfinNative.getSession();
    } catch (error) {
      return JellyfinNative.fail('getSession', error);
    }
  }

  static async getHome(): Promise<string> {
    try {
      return await jellyfinNative.getHome();
    } catch (error) {
      return JellyfinNative.fail('getHome', error);
    }
  }

  static async getHomeSection(section: string, limit: number = 16): Promise<string> {
    try {
      return await jellyfinNative.getHomeSection(section, limit);
    } catch (error) {
      return JellyfinNative.fail('getHomeSection', error);
    }
  }

  static async getBrowseItems(browseType: string, startIndex: number, limit: number, parentId: string = ''): Promise<string> {
    try {
      return await jellyfinNative.getBrowseItems(browseType, startIndex, limit, parentId);
    } catch (error) {
      return JellyfinNative.fail('getBrowseItems', error);
    }
  }

  static async queryItems(optionsJson: string): Promise<string> {
    try {
      return await jellyfinNative.queryItems(optionsJson);
    } catch (error) {
      return JellyfinNative.fail('queryItems', error);
    }
  }

  static async getGenres(parentId: string, startIndex: number, limit: number): Promise<string> {
    try {
      return await jellyfinNative.getGenres(parentId, startIndex, limit);
    } catch (error) {
      return JellyfinNative.fail('getGenres', error);
    }
  }

  static async getStudios(parentId: string, startIndex: number, limit: number): Promise<string> {
    try {
      return await jellyfinNative.getStudios(parentId, startIndex, limit);
    } catch (error) {
      return JellyfinNative.fail('getStudios', error);
    }
  }

  static async getSuggestions(parentId: string, limit: number): Promise<string> {
    try {
      return await jellyfinNative.getSuggestions(parentId, limit);
    } catch (error) {
      return JellyfinNative.fail('getSuggestions', error);
    }
  }

  static async getLibraryItems(parentId: string, startIndex: number, limit: number): Promise<string> {
    try {
      return await jellyfinNative.getLibraryItems(parentId, startIndex, limit);
    } catch (error) {
      return JellyfinNative.fail('getLibraryItems', error);
    }
  }

  /**
   * 搜索条目。
   *
   * @param parentId 限定媒体库（"在某个库里搜索"），空串表示全库
   * @param includeItemTypes 限定类型（`Movie,Series,Episode,Audio,MusicAlbum,BoxSet`），空串表示默认集合
   */
  static async search(query: string, startIndex: number = 0, limit: number = 40,
                      parentId: string = '', includeItemTypes: string = ''): Promise<string> {
    try {
      return await jellyfinNative.search(query, startIndex, limit, parentId, includeItemTypes);
    } catch (error) {
      return JellyfinNative.fail('search', error);
    }
  }

  static async getItemDetail(itemId: string): Promise<string> {
    try {
      return await jellyfinNative.getItemDetail(itemId);
    } catch (error) {
      return JellyfinNative.fail('getItemDetail', error);
    }
  }

  static async getPlaybackInfo(itemId: string, optionsJson: string = '{}'): Promise<string> {
    try {
      return await jellyfinNative.getPlaybackInfo(itemId, optionsJson);
    } catch (error) {
      return JellyfinNative.fail('getPlaybackInfo', error);
    }
  }

  static async toggleFavorite(itemId: string, favorite: boolean): Promise<string> {
    try {
      return await jellyfinNative.toggleFavorite(itemId, favorite);
    } catch (error) {
      return JellyfinNative.fail('toggleFavorite', error);
    }
  }

  static async togglePlayed(itemId: string, played: boolean): Promise<string> {
    try {
      return await jellyfinNative.togglePlayed(itemId, played);
    } catch (error) {
      return JellyfinNative.fail('togglePlayed', error);
    }
  }

  static async getUserItemData(itemId: string): Promise<string> {
    try {
      return await jellyfinNative.getUserItemData(itemId);
    } catch (error) {
      return JellyfinNative.fail('getUserItemData', error);
    }
  }

  static async getUserById(userId: string): Promise<string> {
    try {
      return await jellyfinNative.getUserById(userId);
    } catch (error) {
      return JellyfinNative.fail('getUserById', error);
    }
  }

  static async updateUserConfiguration(configurationJson: string): Promise<string> {
    try {
      return await jellyfinNative.updateUserConfiguration(configurationJson);
    } catch (error) {
      return JellyfinNative.fail('updateUserConfiguration', error);
    }
  }

  static async searchHints(query: string, limit: number = 12, parentId: string = '',
                           includeItemTypes: string = ''): Promise<string> {
    try {
      return await jellyfinNative.searchHints(query, limit, parentId, includeItemTypes);
    } catch (error) {
      return JellyfinNative.fail('searchHints', error);
    }
  }

  static async getPlaylists(): Promise<string> {
    try {
      return await jellyfinNative.getPlaylists();
    } catch (error) {
      return JellyfinNative.fail('getPlaylists', error);
    }
  }

  static async createPlaylist(name: string, itemId: string,
                             mediaType: string = 'Video'): Promise<string> {
    try {
      return await jellyfinNative.createPlaylist(name, itemId, mediaType);
    } catch (error) {
      return JellyfinNative.fail('createPlaylist', error);
    }
  }

  static async addToPlaylist(playlistId: string, itemId: string): Promise<string> {
    try {
      return await jellyfinNative.addToPlaylist(playlistId, itemId);
    } catch (error) {
      return JellyfinNative.fail('addToPlaylist', error);
    }
  }

  /** 播放列表内容（条目里带 PlaylistItemId，移除/排序要用它） */
  static async getPlaylistItems(playlistId: string, startIndex: number = 0,
                               limit: number = 200): Promise<string> {
    try {
      return await jellyfinNative.getPlaylistItems(playlistId, startIndex, limit);
    } catch (error) {
      return JellyfinNative.fail('getPlaylistItems', error);
    }
  }

  static async removeFromPlaylist(playlistId: string, entryIds: string): Promise<string> {
    try {
      return await jellyfinNative.removeFromPlaylist(playlistId, entryIds);
    } catch (error) {
      return JellyfinNative.fail('removeFromPlaylist', error);
    }
  }

  static async movePlaylistItem(playlistId: string, entryId: string,
                                newIndex: number): Promise<string> {
    try {
      return await jellyfinNative.movePlaylistItem(playlistId, entryId, newIndex);
    } catch (error) {
      return JellyfinNative.fail('movePlaylistItem', error);
    }
  }

  static async deletePlaylist(playlistId: string): Promise<string> {
    try {
      return await jellyfinNative.deletePlaylist(playlistId);
    } catch (error) {
      return JellyfinNative.fail('deletePlaylist', error);
    }
  }

  static async reportPlaybackProgress(itemId: string, positionTicks: number, isPaused: boolean): Promise<string> {
    try {
      return await jellyfinNative.reportPlaybackProgress(itemId, positionTicks, isPaused);
    } catch (error) {
      return JellyfinNative.fail('reportPlaybackProgress', error);
    }
  }

  static async reportPlaybackStopped(itemId: string, positionTicks: number): Promise<string> {
    try {
      return await jellyfinNative.reportPlaybackStopped(itemId, positionTicks);
    } catch (error) {
      return JellyfinNative.fail('reportPlaybackStopped', error);
    }
  }

  static async playerOpen(itemId: string, optionsJson: string = '{}'): Promise<string> {
    try {
      return await jellyfinNative.playerOpen(itemId, optionsJson);
    } catch (error) {
      return JellyfinNative.fail('playerOpen', error);
    }
  }

  /**
   * FFmpeg 软解码探测：解析播放地址 → 取前缀字节 → 软解出前若干帧（可落盘首帧 PNG）。
   * 返回 JSON，字段见 native/napi/jellyfin_napi.cpp 的 PlayerSoftDecodeProbe。
   */
  static async playerSoftDecodeProbe(itemId: string, cacheDir: string,
                                     optionsJson: string = '{}'): Promise<string> {
    try {
      return await jellyfinNative.playerSoftDecodeProbe(itemId, cacheDir, optionsJson);
    } catch (error) {
      return JellyfinNative.fail('playerSoftDecodeProbe', error);
    }
  }

  static playerPlay(): string {
    try {
      return jellyfinNative.playerPlay();
    } catch (error) {
      return JellyfinNative.fail('playerPlay', error);
    }
  }

  static playerPause(): string {
    try {
      return jellyfinNative.playerPause();
    } catch (error) {
      return JellyfinNative.fail('playerPause', error);
    }
  }

  static playerSeek(positionTicks: number): string {
    try {
      return jellyfinNative.playerSeek(positionTicks);
    } catch (error) {
      return JellyfinNative.fail('playerSeek', error);
    }
  }

  static playerStop(): string {
    try {
      return jellyfinNative.playerStop();
    } catch (error) {
      return JellyfinNative.fail('playerStop', error);
    }
  }

  static playerGetState(): string {
    try {
      return jellyfinNative.playerGetState();
    } catch (error) {
      return JellyfinNative.fail('playerGetState', error);
    }
  }

  static async adminListUsers(): Promise<string> {
    try {
      return await jellyfinNative.adminListUsers();
    } catch (error) {
      return JellyfinNative.fail('adminListUsers', error);
    }
  }

  static async adminListDevices(): Promise<string> {
    try {
      return await jellyfinNative.adminListDevices();
    } catch (error) {
      return JellyfinNative.fail('adminListDevices', error);
    }
  }

  static async adminListTasks(): Promise<string> {
    try {
      return await jellyfinNative.adminListTasks();
    } catch (error) {
      return JellyfinNative.fail('adminListTasks', error);
    }
  }

  static async adminGetSystemInfo(): Promise<string> {
    try {
      return await jellyfinNative.adminGetSystemInfo();
    } catch (error) {
      return JellyfinNative.fail('adminGetSystemInfo', error);
    }
  }

  static async adminGenericGet(path: string): Promise<string> {
    try {
      return await jellyfinNative.adminGenericGet(path);
    } catch (error) {
      return JellyfinNative.fail('adminGenericGet', error);
    }
  }

  static async adminGenericPost(path: string, bodyJson: string): Promise<string> {
    try {
      return await jellyfinNative.adminGenericPost(path, bodyJson);
    } catch (error) {
      return JellyfinNative.fail('adminGenericPost', error);
    }
  }

  static async adminGenericPostNoBody(path: string): Promise<string> {
    try {
      return await jellyfinNative.adminGenericPostNoBody(path);
    } catch (error) {
      return JellyfinNative.fail('adminGenericPostNoBody', error);
    }
  }

  static async adminGenericDelete(path: string): Promise<string> {
    try {
      return await jellyfinNative.adminGenericDelete(path);
    } catch (error) {
      return JellyfinNative.fail('adminGenericDelete', error);
    }
  }

  static setPreference(key: string, value: string): string {
    try {
      return jellyfinNative.setPreference(key, value);
    } catch (error) {
      return JellyfinNative.fail('setPreference', error);
    }
  }

  static getPreferences(): string {
    try {
      return jellyfinNative.getPreferences();
    } catch (error) {
      return JellyfinNative.fail('getPreferences', error);
    }
  }

  static getImageUrl(itemId: string, imageType: string, maxWidth: number, tag: string): string {
    try {
      return jellyfinNative.getImageUrl(itemId, imageType, maxWidth, tag);
    } catch (error) {
      return JellyfinNative.fail('getImageUrl', error);
    }
  }

  /**
   * 外挂字幕地址（播放中切换字幕）：服务端按格式转换后直接取回，交给播放器叠加。
   * 返回 JSON：{ ok, data: { url, format, codec, imageSubtitle } }
   */
  static subtitleUrl(itemId: string, mediaSourceId: string, streamIndex: number,
                     codec: string): string {
    try {
      return jellyfinNative.subtitleUrl(itemId, mediaSourceId, streamIndex, codec);
    } catch (error) {
      return JellyfinNative.fail('subtitleUrl', error);
    }
  }

  static setImageCacheDir(dir: string): string {
    try {
      return jellyfinNative.setImageCacheDir(dir);
    } catch (error) {
      return JellyfinNative.fail('setImageCacheDir', error);
    }
  }

  /**
   * 软解播放会话：打开流式软解（FFmpeg Range 取流 + 逐帧 RGBA），供逐帧渲染使用。
   * 返回 JSON，字段见 native/napi/jellyfin_napi.cpp 的 SoftPlayOpen。
   */
  static async softPlayOpen(itemId: string, surfaceId: string = '', surfaceWidth: number = 0,
                            surfaceHeight: number = 0, renderMode: string = 'surface',
                            optionsJson: string = '{}'): Promise<string> {
    try {
      return await jellyfinNative.softPlayOpen(itemId, surfaceId, surfaceWidth, surfaceHeight,
                                              renderMode, optionsJson);
    } catch (error) {
      return JellyfinNative.fail('softPlayOpen', error);
    }
  }

  /** 取下一帧（同步）：返回 {ok,width,height,ptsSec,frameIndex,pixels} */
  /**
   * 取下一帧（异步）。返回 JSON（用 `parseResult` 解）：
   * `data = { ok, width, height, ptsSec, frameIndex, bytesFetched, rendered, error?, renderError? }`
   */
  static async softPlayNextFrame(maxWidth: number): Promise<string> {
    try {
      return await jellyfinNative.softPlayNextFrame(maxWidth);
    } catch (error) {
      return JellyfinNative.fail('softPlayNextFrame', error);
    }
  }

  /** 把最近一帧渲染上屏（须在 UI 线程调用；返回 JSON，用 parseResult 解） */
  static softPlayRenderLast(): string {
    try {
      return jellyfinNative.softPlayRenderLast();
    } catch (error) {
      return JellyfinNative.fail('softPlayRenderLast', error);
    }
  }

  static softPlayStatus(): string {
    try {
      return jellyfinNative.softPlayStatus();
    } catch (error) {
      return JellyfinNative.fail('softPlayStatus', error);
    }
  }

  /** 回读当前渲染缓冲并写成 PNG（验证渲染结果，与系统截图无关） */
  static softPlayDumpFrame(path: string): string {
    try {
      return jellyfinNative.softPlayDumpFrame(path);
    } catch (error) {
      return JellyfinNative.fail('softPlayDumpFrame', error);
    }
  }

  /** 渲染自检：清屏为红并回读（判断 surface 能否作为 GL 渲染目标） */
  static softPlaySelfTest(): string {
    try {
      return jellyfinNative.softPlaySelfTest();
    } catch (error) {
      return JellyfinNative.fail('softPlaySelfTest', error);
    }
  }

  /** 渲染目标判定：给定 surfaceId 即初始化 EGL 并清屏回读（无需开始播放） */
  static renderTargetProbe(surfaceId: string, width: number, height: number,
                           renderMode: string = 'texture'): string {
    try {
      return jellyfinNative.renderTargetProbe(surfaceId, width, height, renderMode);
    } catch (error) {
      return JellyfinNative.fail('renderTargetProbe', error);
    }
  }

  static softPlayClose(): string {
    try {
      return jellyfinNative.softPlayClose();
    } catch (error) {
      return JellyfinNative.fail('softPlayClose', error);
    }
  }

  /** 软解会话 seek：跳转到指定时间点（秒），用于续播 */
  static softPlaySeek(positionSec: number): string {
    try {
      return jellyfinNative.softPlaySeek(positionSec);
    } catch (error) {
      return JellyfinNative.fail('softPlaySeek', error);
    }
  }

  /** 读取 XComponent 视频区域的最新触摸事件（由 DispatchTouchEvent 捕获） */
  static getXComponentTouchEvent(): string {
    try {
      return jellyfinNative.getXComponentTouchEvent();
    } catch (error) {
      return JellyfinNative.fail('getXComponentTouchEvent', error);
    }
  }

  /** 配置 HTTPS 用的 CA 根证书 PEM 路径（未配置则 https 连接会明确失败） */
  static setCaBundlePath(path: string): string {
    try {
      return jellyfinNative.setCaBundlePath(path);
    } catch (error) {
      return JellyfinNative.fail('setCaBundlePath', error);
    }
  }

  /** 查询 CA 根证书是否已加载（诊断用） */
  static hasCaBundle(): string {
    try {
      return jellyfinNative.hasCaBundle();
    } catch (error) {
      return JellyfinNative.fail('hasCaBundle', error);
    }
  }

  static async loadImage(url: string): Promise<string> {
    try {
      return await jellyfinNative.loadImage(url);
    } catch (error) {
      return JellyfinNative.fail('loadImage', error);
    }
  }

  static clearImageCache(): string {
    try {
      return jellyfinNative.clearImageCache();
    } catch (error) {
      return JellyfinNative.fail('clearImageCache', error);
    }
  }

  static async getSeasonEpisodes(seriesId: string, seasonId: string): Promise<string> {
    try {
      return await jellyfinNative.getSeasonEpisodes(seriesId, seasonId);
    } catch (error) {
      return JellyfinNative.fail('getSeasonEpisodes', error);
    }
  }
}
