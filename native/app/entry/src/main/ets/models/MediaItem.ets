import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { formatTicks } from '../common/format';
import { JsonUtil } from '../common/JsonUtil';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';

/**
 * UI media item mapped from Jellyfin JSON.
 */
export class MediaItem {
  id: string = '';
  name: string = '';
  type: string = '';
  year: string = '';
  imageTag: string = '';
  backdropTag: string = '';
  overview: string = '';
  runTimeTicks: number = 0;
  playbackPositionTicks: number = 0;
  communityRating: number = 0;
  officialRating: string = '';
  isFolder: boolean = false;
  isFavorite: boolean = false;
  isPlayed: boolean = false;
  collectionType: string = '';
  seriesName: string = '';
  indexNumber: number = 0;
  genres: string[] = [];
  /**
   * 播放列表条目 id（`PlaylistItemId`）。
   *
   * 只有"从播放列表里读出来的条目"才有这个字段，它**不同于**媒体条目 id：
   * 服务端的"移除条目/移动条目"接口认的是列表条目 id，
   * 设备实测用媒体 id 去删会返回 204 但什么都不删（静默失败）。
   */
  playlistItemId: string = '';
  /**
   * 子项数量（Jellyfin `ChildCount`）：播放列表条目数、合集内影片数。
   *
   * 需要显式在 `Fields` 里请求（播放列表查询与合集查询都已带上）。
   */
  childCount: number = 0;

  progress(): number {
    if (this.runTimeTicks <= 0 || this.playbackPositionTicks <= 0) {
      return 0;
    }
    const p: number = this.playbackPositionTicks / this.runTimeTicks;
    if (p >= 0.95) {
      return 0;
    }
    return Math.min(1, Math.max(0, p));
  }

  metaLine(): string {
    const parts: string[] = [];
    // 播放列表/合集先给"共 N 项"——这类条目本身没有年份/时长，数量才是用户关心的信息
    if (this.childCount > 0 && (this.type === 'Playlist' || this.type === 'BoxSet')) {
      parts.push(`${this.childCount} 项`);
    }
    if (this.year.length > 0) {
      parts.push(this.year);
    }
    if (this.communityRating > 0) {
      // 用文字"分"表示评分，不再用 ★ 字符当图标（参考项目里图标一律用系统符号）
      parts.push(`${this.communityRating.toFixed(1)} 分`);
    }
    if (this.runTimeTicks > 0 && this.type !== 'Series' && this.type !== 'BoxSet' &&
      this.type !== 'CollectionFolder') {
      const runtime = formatTicks(this.runTimeTicks);
      if (runtime !== '--:--') {
        parts.push(runtime);
      }
    }
    return parts.join(' · ');
  }

  displayTitle(): string {
    if (this.type === 'Episode' && this.indexNumber > 0) {
      return `E${this.indexNumber} ${this.name}`;
    }
    return this.name;
  }

  typeLabel(): string {
    if (this.type === 'Movie') {
      return '电影';
    }
    if (this.type === 'Series') {
      return '剧集';
    }
    if (this.type === 'Episode') {
      return '单集';
    }
    if (this.type === 'BoxSet') {
      return '合集';
    }
    if (this.type === 'Playlist') {
      return '播放列表';
    }
    if (this.type === 'Audio' || this.type === 'MusicAlbum') {
      return '音乐';
    }
    if (this.isFolder || this.type === 'CollectionFolder' || this.type === 'Folder') {
      return '文件夹';
    }
    return this.type;
  }

  imageUrl(maxWidth: number = 300, imageType: string = 'Primary'): string {
    if (this.id.length === 0) {
      return '';
    }
    const tag: string = imageType === 'Backdrop' ? this.backdropTag : this.imageTag;
    const raw: string = JellyfinNative.getImageUrl(this.id, imageType, maxWidth, tag);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      return '';
    }
    return JsonUtil.getString(result.data, 'url', '');
  }

  static fromJson(obj: Object | null): MediaItem {
    const item: MediaItem = new MediaItem();
    if (obj === null || obj === undefined) {
      return item;
    }
    const data: ESObject = obj as ESObject;
    item.id = JsonUtil.getString(data, 'Id', JsonUtil.getString(data, 'id', ''));
    item.name = JsonUtil.getString(data, 'Name', JsonUtil.getString(data, 'name', ''));
    item.type = JsonUtil.getString(data, 'Type',
      JsonUtil.getString(data, 'CollectionType', JsonUtil.getString(data, 'type', '')));
    item.collectionType = JsonUtil.getString(data, 'CollectionType', '');
    const yearNum: number = JsonUtil.getNumber(data, 'ProductionYear', 0);
    item.year = yearNum > 0 ? `${yearNum}` : JsonUtil.getString(data, 'ProductionYear', '');
    item.overview = JsonUtil.getString(data, 'Overview', '');
    item.runTimeTicks = JsonUtil.getNumber(data, 'RunTimeTicks', 0);
    item.communityRating = JsonUtil.getNumber(data, 'CommunityRating', 0);
    item.officialRating = JsonUtil.getString(data, 'OfficialRating', '');
    item.seriesName = JsonUtil.getString(data, 'SeriesName', '');
    item.indexNumber = JsonUtil.getNumber(data, 'IndexNumber', 0);
    item.playlistItemId = JsonUtil.getString(data, 'PlaylistItemId', '');
    item.childCount = JsonUtil.getNumber(data, 'ChildCount', 0);
    item.isFolder = item.type === 'CollectionFolder' || item.type === 'UserView' ||
      item.type === 'Folder' || item.type === 'BoxSet';

    const userData: ESObject | null = JsonUtil.getObject(data, 'UserData');
    if (userData !== null) {
      item.playbackPositionTicks = JsonUtil.getNumber(userData, 'PlaybackPositionTicks', 0);
      item.isFavorite = JsonUtil.getBoolean(userData, 'IsFavorite', false);
      item.isPlayed = JsonUtil.getBoolean(userData, 'Played', false);
    }

    const tags: ESObject | null = JsonUtil.getObject(data, 'ImageTags');
    if (tags !== null) {
      item.imageTag = JsonUtil.getString(tags, 'Primary', JsonUtil.getString(tags, 'primary', ''));
    }
    if (item.imageTag.length === 0) {
      item.imageTag = JsonUtil.getString(data, 'PrimaryImageTag', '');
    }

    const backdrops: Object[] = JsonUtil.getArray(data, 'BackdropImageTags');
    if (backdrops.length > 0 && typeof backdrops[0] === 'string') {
      item.backdropTag = backdrops[0] as string;
    }

    const genreArr: Object[] = JsonUtil.getArray(data, 'Genres');
    const genres: string[] = [];
    for (let i = 0; i < genreArr.length; i++) {
      if (typeof genreArr[i] === 'string') {
        genres.push(genreArr[i] as string);
      }
    }
    item.genres = genres;
    return item;
  }

  static fromArray(arr: Object[]): MediaItem[] {
    const out: MediaItem[] = [];
    for (let i = 0; i < arr.length; i++) {
      out.push(MediaItem.fromJson(arr[i]));
    }
    return out;
  }
}
