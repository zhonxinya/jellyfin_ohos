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

  static async search(query: string, startIndex: number = 0, limit: number = 40): Promise<string> {
    try {
      return await jellyfinNative.search(query, startIndex, limit);
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

  static async searchHints(query: string, limit: number = 12): Promise<string> {
    try {
      return await jellyfinNative.searchHints(query, limit);
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

  static async createPlaylist(name: string, itemId: string): Promise<string> {
    try {
      return await jellyfinNative.createPlaylist(name, itemId);
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

  static setImageCacheDir(dir: string): string {
    try {
      return jellyfinNative.setImageCacheDir(dir);
    } catch (error) {
      return JellyfinNative.fail('setImageCacheDir', error);
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
