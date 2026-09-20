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
  /**
   * 所属剧集的 id（Jellyfin `SeriesId`，仅 `Episode` 或"代表剧集的横幅条目"有值）。
   *
   * 为什么需要：短视频页把**电视剧当作一个作品**展示（一屏一条），但真正能播的
   * 是它下面某一集 —— 于是列表条目的 `id` 会被换成"按播放历史算出的那一集"，
   * 而 `seriesId` 记住它原本代表哪部剧。进详情页要用 `seriesId`（用户点的是"这部作品"），
   * 收藏/播放则用 `id`（作用于当前集）。两者的区别见 `ShortVideoPage.detailId()`。
   */
  seriesId: string = '';
  indexNumber: number = 0;
  /** 季号（Jellyfin `ParentIndexNumber`，仅 `Episode` 有值） */
  parentIndexNumber: number = 0;
  /**
   * 「这将是第几集」的标签（如 `第 1 集` / `第 2 季 第 5 集`）。
   *
   * 只有短视频页"把电视剧当作一个作品"生成的条目才有值：那种条目的标题是**剧名**，
   * 需要另用一行说明"进去会播哪一集"。普通条目为空，界面不渲染这一行。
   */
  episodeLabel: string = '';
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
    // 短视频页把电视剧折叠成"作品"后，标题已经是**剧名**、集号由 `episodeLabel`
    // 单独一行承担（见 ShortVideoPage.asSeriesEntry）。这里若再加 `E{n}` 前缀，
    // 同一条内容会同时出现 `E1 邪恶力量`（标题）与 `第 1 季 第 1 集`（标签）——
    // 同一信息说两遍，且 `E1` 这种写法对用户不友好（设备实测踩到）。
    if (this.episodeLabel.length > 0) {
      return this.name;
    }
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
    item.seriesId = JsonUtil.getString(data, 'SeriesId',
      JsonUtil.getString(data, 'seriesId', ''));
    item.indexNumber = JsonUtil.getNumber(data, 'IndexNumber', 0);
    item.parentIndexNumber = JsonUtil.getNumber(data, 'ParentIndexNumber', 0);
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
