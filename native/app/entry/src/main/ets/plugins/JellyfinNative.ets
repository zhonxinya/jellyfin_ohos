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

  /**
   * 当前用户的媒体库视图（`/Users/{id}/Views`）。
   * 返回 `{ Items: [{ Id, Name, CollectionType }] }`；`Id` 就是用户配置里
   * `OrderedViews` / `MyMediaExcludes` / `LatestItemsExcludes` / `GroupedFolders` 引用的值。
   */
  static async getUserViews(): Promise<string> {
    try {
      return await jellyfinNative.getUserViews();
    } catch (error) {
      return JellyfinNative.fail('getUserViews', error);
    }
  }

  /**
   * 只改若干用户配置字段。
   *
   * 传 `{ "HidePlayedInLatest": true }` 这样的**增量**对象即可：
   * 原生侧会先 GET 当前 `Configuration`，把增量合并进去，再整体提交。
   * 千万不要自己拼"完整配置"往服务端发 —— 服务端把提交对象的每个字段都抄进用户记录，
   * 少带的字段会被重置成默认值。
   */
  static async patchUserConfiguration(patchJson: string): Promise<string> {
    try {
      return await jellyfinNative.patchUserConfiguration(patchJson);
    } catch (error) {
      return JellyfinNative.fail('patchUserConfiguration', error);
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

  /**
   * 日志文件正文的结尾一段。
   *
   * 服务端 `/System/Logs/Log` 返回**整份文件**且没有 range/tail 支持，
   * 而一天的文件实测有 15.5 MB —— 所以原生侧只把结尾 `keepTailBytes` 字节交过来
   * （`data = { text, truncated, totalBytes }`）。
   */
  static async adminGetLogText(name: string, keepTailBytes: number): Promise<string> {
    try {
      return await jellyfinNative.adminGetLogText(name, keepTailBytes);
    } catch (error) {
      return JellyfinNative.fail('adminGetLogText', error);
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

  // ── 媒体库管理（设置 → 媒体库）──────────────────────────────────────────
  // 统一走 C++ `core/api/library_admin_api.*`：这里不拼 URL、不拼 query，
  // 返回的 `data` 已是归一化后的 UI 模型，页面只做展示与表单状态管理。

  static async libraryVirtualFolders(): Promise<string> {
    try {
      return await jellyfinNative.libraryVirtualFolders();
    } catch (error) {
      return JellyfinNative.fail('libraryVirtualFolders', error);
    }
  }

  /** 新增/编辑媒体库时的可选项（语言、抓取器、图片类型），`data` 见 LibraryModels.ets */
  static async libraryAvailableOptions(contentType: string, isNewLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryAvailableOptions(contentType, isNewLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryAvailableOptions', error);
    }
  }

  /** 首选元数据语言 + 国家/地区，`data = { languages, countries }` */
  static async libraryLocalization(): Promise<string> {
    try {
      return await jellyfinNative.libraryLocalization();
    } catch (error) {
      return JellyfinNative.fail('libraryLocalization', error);
    }
  }

  static async libraryAddVirtualFolder(name: string, collectionType: string, pathsJson: string,
                                       optionsJson: string, refreshLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryAddVirtualFolder(name, collectionType, pathsJson,
        optionsJson, refreshLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryAddVirtualFolder', error);
    }
  }

  static async libraryRenameVirtualFolder(name: string, newName: string,
                                          refreshLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryRenameVirtualFolder(name, newName, refreshLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryRenameVirtualFolder', error);
    }
  }

  static async libraryRemoveVirtualFolder(name: string, refreshLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryRemoveVirtualFolder(name, refreshLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryRemoveVirtualFolder', error);
    }
  }

  static async libraryAddMediaPath(name: string, path: string, networkPath: string,
                                   refreshLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryAddMediaPath(name, path, networkPath, refreshLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryAddMediaPath', error);
    }
  }

  static async libraryUpdateMediaPath(name: string, path: string, networkPath: string): Promise<string> {
    try {
      return await jellyfinNative.libraryUpdateMediaPath(name, path, networkPath);
    } catch (error) {
      return JellyfinNative.fail('libraryUpdateMediaPath', error);
    }
  }

  static async libraryRemoveMediaPath(name: string, path: string, refreshLibrary: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryRemoveMediaPath(name, path, refreshLibrary);
    } catch (error) {
      return JellyfinNative.fail('libraryRemoveMediaPath', error);
    }
  }

  static async libraryUpdateOptions(itemId: string, optionsJson: string): Promise<string> {
    try {
      return await jellyfinNative.libraryUpdateOptions(itemId, optionsJson);
    } catch (error) {
      return JellyfinNative.fail('libraryUpdateOptions', error);
    }
  }

  static async libraryScanAll(): Promise<string> {
    try {
      return await jellyfinNative.libraryScanAll();
    } catch (error) {
      return JellyfinNative.fail('libraryScanAll', error);
    }
  }

  static async libraryScanFolder(itemId: string, metadataRefreshMode: string, imageRefreshMode: string,
                                 replaceAllMetadata: boolean, replaceAllImages: boolean): Promise<string> {
    try {
      return await jellyfinNative.libraryScanFolder(itemId, metadataRefreshMode, imageRefreshMode,
        replaceAllMetadata, replaceAllImages);
    } catch (error) {
      return JellyfinNative.fail('libraryScanFolder', error);
    }
  }

  /** 服务器级媒体库设置：返回已补齐默认值的完整 ServerConfiguration（可原样回传） */
  static async libraryServerConfig(): Promise<string> {
    try {
      return await jellyfinNative.libraryServerConfig();
    } catch (error) {
      return JellyfinNative.fail('libraryServerConfig', error);
    }
  }

  /** 整体替换服务器配置：`configJson` 必须是 `libraryServerConfig()` 的完整对象 */
  static async libraryUpdateServerConfig(configJson: string): Promise<string> {
    try {
      return await jellyfinNative.libraryUpdateServerConfig(configJson);
    } catch (error) {
      return JellyfinNative.fail('libraryUpdateServerConfig', error);
    }
  }

  /** 条目已有图片（`ImageInfo[]`）：用来显示"当前封面 1280×720"这类事实 */
  static async libraryCoverInfo(itemId: string): Promise<string> {
    try {
      return await jellyfinNative.libraryCoverInfo(itemId);
    } catch (error) {
      return JellyfinNative.fail('libraryCoverInfo', error);
    }
  }

  /** 让服务器去抓取给定 URL 的图片作为封面（客户端只传 URL，不需要自己下载/上传二进制） */
  static async librarySetCoverFromUrl(itemId: string, imageType: string,
                                      imageUrl: string): Promise<string> {
    try {
      return await jellyfinNative.librarySetCoverFromUrl(itemId, imageType, imageUrl);
    } catch (error) {
      return JellyfinNative.fail('librarySetCoverFromUrl', error);
    }
  }

  /** 删除封面；`imageIndex` 传 -1 表示按类型整组删除 */
  static async libraryDeleteCover(itemId: string, imageType: string,
                                  imageIndex: number): Promise<string> {
    try {
      return await jellyfinNative.libraryDeleteCover(itemId, imageType, imageIndex);
    } catch (error) {
      return JellyfinNative.fail('libraryDeleteCover', error);
    }
  }

  /**
   * 服务器级元数据设置：`{ config, savers, itemTypes }`。
   * `config` 是**整份** ServerConfiguration（可原样交给 `libraryUpdateServerConfig`）——
   * 元数据抓取器配置存在 `ServerConfiguration.MetadataOptions` 里，而 keyed 路由
   * `/System/Configuration/metadataoptions` 实测 404，所以只能整份读写。
   */
  static async libraryMetadataSettings(): Promise<string> {
    try {
      return await jellyfinNative.libraryMetadataSettings();
    } catch (error) {
      return JellyfinNative.fail('libraryMetadataSettings', error);
    }
  }

  /**
   * 读某一段命名配置（`GET /System/Configuration/{key}`）。
   * key 用写死的常量（NFO 段是 `xbmcmetadata`；`nfo` 这个 key 实测 404）。
   */
  static async libraryNamedConfig(key: string): Promise<string> {
    try {
      return await jellyfinNative.libraryNamedConfig(key);
    } catch (error) {
      return JellyfinNative.fail('libraryNamedConfig', error);
    }
  }

  /** 整体替换某一段命名配置（`POST /System/Configuration/{key}`，只替换这一段） */
  static async libraryUpdateNamedConfig(key: string, configJson: string): Promise<string> {
    try {
      return await jellyfinNative.libraryUpdateNamedConfig(key, configJson);
    } catch (error) {
      return JellyfinNative.fail('libraryUpdateNamedConfig', error);
    }
  }

  // ── 条目（影视）元数据管理 ─────────────────────────────────────────────────
  // 与 library* 同一套：这里只接线，路径 / 请求体形状在 C++ `core/api/item_metadata_api.*`，
  // 由主机单测逐字断言（`native/core/tests/test_item_metadata_api.cpp`）。

  /** 条目完整 DTO + 元数据编辑器信息（`data: { item, editor, editorError }`） */
  static async itemMetadata(itemId: string): Promise<string> {
    try {
      return await jellyfinNative.itemMetadata(itemId);
    } catch (error) {
      return JellyfinNative.fail('itemMetadata', error);
    }
  }

  /**
   * 整体替换条目元数据（`POST /Items/{itemId}`）。
   * `itemJson` 必须是**完整条目对象** —— 少带字段会被服务端清空（见 native 侧注释）。
   */
  static async itemUpdateMetadata(itemId: string, itemJson: string): Promise<string> {
    try {
      return await jellyfinNative.itemUpdateMetadata(itemId, itemJson);
    } catch (error) {
      return JellyfinNative.fail('itemUpdateMetadata', error);
    }
  }

  /** 该条目可用的外部 ID 提供方（`GET /Items/{itemId}/ExternalIdInfos`） */
  static async itemExternalIdInfos(itemId: string): Promise<string> {
    try {
      return await jellyfinNative.itemExternalIdInfos(itemId);
    } catch (error) {
      return JellyfinNative.fail('itemExternalIdInfos', error);
    }
  }

  /** 设置条目内容类型覆盖（空串 = 清除覆盖，回到从媒体库继承） */
  static async itemUpdateContentType(itemId: string, contentType: string): Promise<string> {
    try {
      return await jellyfinNative.itemUpdateContentType(itemId, contentType);
    } catch (error) {
      return JellyfinNative.fail('itemUpdateContentType', error);
    }
  }

  /** 刷新条目元数据（`POST /Items/{itemId}/Refresh`） */
  static async itemRefreshMetadata(itemId: string, metadataRefreshMode: string,
                                   imageRefreshMode: string, replaceAllMetadata: boolean,
                                   replaceAllImages: boolean): Promise<string> {
    try {
      return await jellyfinNative.itemRefreshMetadata(itemId, metadataRefreshMode,
        imageRefreshMode, replaceAllMetadata, replaceAllImages);
    } catch (error) {
      return JellyfinNative.fail('itemRefreshMetadata', error);
    }
  }

  /** 远程搜索（识别）候选条目 */
  static async itemRemoteSearch(itemType: string, searchTerm: string, providerIdsJson: string,
                                year: number, metadataLanguage: string,
                                metadataCountryCode: string, itemId: string): Promise<string> {
    try {
      return await jellyfinNative.itemRemoteSearch(itemType, searchTerm, providerIdsJson, year,
        metadataLanguage, metadataCountryCode, itemId);
    } catch (error) {
      return JellyfinNative.fail('itemRemoteSearch', error);
    }
  }

  /** 应用识别结果（会 FullRefresh + 覆盖元数据） */
  static async itemApplyRemoteSearch(itemId: string, resultJson: string,
                                     replaceAllImages: boolean): Promise<string> {
    try {
      return await jellyfinNative.itemApplyRemoteSearch(itemId, resultJson, replaceAllImages);
    } catch (error) {
      return JellyfinNative.fail('itemApplyRemoteSearch', error);
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

  /**
   * 取字幕文本（应用侧自行解析并渲染）。返回 JSON：{ ok, data: { text } }
   *
   * 为什么不用播放器的 `addSubtitleFromUrl`：该 API 的契约要求视频源经 `fdSrc` 设置，
   * 而本工程用 `avPlayer.url`（网络地址）—— 调用会静默成功但**永不取流**
   * （服务端日志可证），字幕因此一直不显示。详见 `common/SubtitleTrack.ets`。
   */
  static fetchSubtitleText(url: string): string {
    try {
      return jellyfinNative.fetchSubtitleText(url);
    } catch (error) {
      return JellyfinNative.fail('fetchSubtitleText', error);
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
   * 在当前线程（UI 线程）初始化/复用软解 EGL 渲染器。
   *
   * **必须在 `softPlayOpen` 成功之后、启动帧循环之前调用，且只能在 UI 线程调用**：
   * EGL 上下文是线程私有状态，初始化线程必须与逐帧 `softPlayRenderLast()` 的线程相同。
   * 历史缺陷：初始化发生在 `softPlayOpen` 的 `RunAsync` 工作线程上，于是 UI 线程的每帧
   * `eglSwapBuffers` 都报 EGL_BAD_SURFACE（0x300d），帧号在涨、**屏幕全黑且无任何报错**。
   *
   * 返回 JSON（用 `parseResult` 解）：
   * `data = { renderReady, renderReused, renderWidth, renderHeight, renderError?,
   *           xcomponentSize?, renderThreadId, surfaceGeneration }`
   */
  static softPlayInitRenderer(surfaceId: string = '', width: number = 0, height: number = 0,
                              renderMode: string = 'xcomponent'): string {
    try {
      return jellyfinNative.softPlayInitRenderer(surfaceId, width, height, renderMode);
    } catch (error) {
      return JellyfinNative.fail('softPlayInitRenderer', error);
    }
  }

  /**
   * 软解播放会话：打开流式软解（FFmpeg Range 取流 + 逐帧 RGBA），供逐帧渲染使用。
   * 返回 JSON，字段见 native/napi/jellyfin_napi.cpp 的 SoftPlayOpen。
   *
   * 注意：本接口**不初始化 EGL 渲染器**（它运行在工作线程上，而 EGL 初始化必须与渲染同线程），
   * 渲染器由宿主随后调用 `softPlayInitRenderer()` 建立。
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

  /**
   * 设置软解画面缩放模式：「视频比例」在软解路径上的落点。
   * 0 适应 / 1 填充 / 2 拉伸 / 3 原始（与 `PlayerAspectMode` 顺序一致）。
   */
  static softPlaySetScale(mode: number): string {
    try {
      return jellyfinNative.softPlaySetScale(mode);
    } catch (error) {
      return JellyfinNative.fail('softPlaySetScale', error);
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

  /**
   * 取某部剧"接着看的那一集"（`/Shows/NextUp?SeriesId=...`）。
   *
   * 服务端语义：看过几集 → 接着看的那一集；一集没看过 → 第一集；全看完 → 空。
   * 短视频页用它把"一部剧"折成一条并定位到该播的那一集。
   */
  static async getNextUpForSeries(seriesId: string): Promise<string> {
    try {
      return await jellyfinNative.getNextUpForSeries(seriesId);
    } catch (error) {
      return JellyfinNative.fail('getNextUpForSeries', error);
    }
  }
}
