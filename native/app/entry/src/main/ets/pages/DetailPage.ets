import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { ItemMetadataRefreshSignal } from '../common/ItemMetadataModels';
import { formatTicks } from '../common/format';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';
import { EpisodeCard } from '../components/EpisodeCard';
import { HorizontalShelf } from '../components/HorizontalShelf';
import { AppIconButton } from '../components/AppIconButton';
import { PrimaryButton } from '../components/PrimaryButton';
import { SecondaryButton } from '../components/SecondaryButton';
import { TextButton } from '../components/TextButton';

/** 音轨/字幕下拉里的「未选择」项（= 不指定轨道，交给服务端用默认轨） */
const TRACK_UNSELECTED: string = '未选择';

/** 剧集卡片宽度（16:9 剧照；高度由 `EpisodeCard` 按宽度推出） */
const EPISODE_CARD_WIDTH: number = 176;
/**
 * 横向剧集列表的固定高度。
 *
 * 横向 `List` 必须显式给高度，否则在纵向 `Scroll` 里会塌成 0（什么都看不见）。
 * 取值 = 卡片最大内容高度（剧照 99 + 间距 6 + 标题 2 行 36 + 间距 6 + 元信息 15 = 162）+ 余量。
 */
const EPISODE_SHELF_HEIGHT: number = 170;
/** 季标签栏高度（含选中下划线） */
const SEASON_TABS_HEIGHT: number = 48;

/** 预计算的媒体流条目，供 Builder 使用 */
interface StreamEntry {
  type: string;
  codec: string;
  sizeLabel: string;
}

@Entry
@Component
struct DetailPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private itemId: string = '';
  @State private item: MediaItem = new MediaItem();
  @State private seasons: MediaItem[] = [];
  @State private similar: MediaItem[] = [];
  @State private people: Object[] = [];
  /**
   * 当前选中的季在 `seasons` 中的下标（-1 = 尚未选中）。
   *
   * 取代了旧的 `expandedSeasonId` 手风琴：旧实现"点一季 → 往下展开一段纵向分集列表"，
   * 多季剧集里想翻到第 5 季要先滚过前四季的全部集数；而且展开状态叠在长列表里，
   * 用户很难判断"我现在看的是第几季"。改成 TAB 后，"选哪一季"与"这一季有哪几集"分开呈现。
   */
  @State private activeSeasonIndex: number = -1;
  /** 当前选中季的分集（横向剧集列表的数据源） */
  @State private episodes: MediaItem[] = [];
  /** 分集列表的加载状态（`UiState` 常量） */
  @State private episodesStatus: string = UiState.INITIAL;
  /**
   * 分集请求序号：每次切季 +1，响应回来时序号已过期就丢弃。
   *
   * 为什么必须要有：快速连点不同季标签时，先发的请求可能后到，
   * 不加这层会把**上一季的分集**盖到当前选中季的下面（内容与标签不符）。
   */
  private episodesSeq: number = 0;
  /**
   * 弹层状态 —— 参考项目用「一个 bindSheet 节点 + sheetKind 判别」承载所有详情页弹层，
   * 不再为每个弹层手写全屏遮罩 + 居中卡片 + 点遮罩关闭（原来有 4 套这样的代码）。
   * '' 表示关闭；其余取值见 `SheetContent()`。
   */
  @State private sheetShow: boolean = false;
  @State private sheetKind: string = '';
  /** 播放起播参数：-1 表示不指定轨道（交给服务端用默认轨），下拉里显示为「未选择」 */
  @State private audioStreamIndex: number = -1;
  @State private subtitleStreamIndex: number = -1;
  @State private forceTranscode: boolean = false;
  @State private mediaStreams: Object[] = [];
  @State private playlistItems: MediaItem[] = [];
  @State private playlistName: string = '';
  @State private playlistMessage: string = '';
  @State private favoriting: boolean = false;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['itemId'];
      if (typeof idVal === 'string') {
        this.itemId = idVal;
      }
    }
    this.loadDetail();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /**
   * 从「编辑元数据」页返回且**真的改过数据**时重载详情。
   *
   * 为什么不无条件重载：`loadDetail()` 会把季标签重置回第 1 季，
   * 而用户从播放页返回详情页时已选中的季不该被清掉（信号按 itemId 精确匹配、取走即清）。
   */
  onPageShow(): void {
    if (this.itemId.length > 0 && ItemMetadataRefreshSignal.consume(this.itemId)) {
      this.reloadKeepingSeason();
    }
  }

  /** 元数据改过后的重载：保留当前选中的季（否则会被重置回第 1 季） */
  private async reloadKeepingSeason(): Promise<void> {
    const season: number = this.activeSeasonIndex;
    await this.loadDetail();
    if (season > 0 && season < this.seasons.length) {
      await this.loadSeasonEpisodes(season);
    }
  }

  /** 打开条目元数据管理页（服务端三个控制器都是 RequiresElevation，入口仅管理员可见） */
  private openMetadataEditor(): void {
    if (this.item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/ItemMetadataPage',
      params: {
        itemId: this.item.id,
        itemType: this.item.type,
        title: this.item.displayTitle()
      }
    });
  }

  /**
   * 音乐条目转交专用页面（专辑 / 艺术家 / 单曲）。
   *
   * 用 `replaceUrl`：本页已经请求过一次详情、且渲染不出音乐需要的控件，
   * 留在栈上只会让"返回"回到一个空页面。
   */
  private redirectMusic(): void {
    if (this.item.type === 'MusicArtist') {
      router.replaceUrl({
        url: 'pages/ArtistDetailPage',
        params: { artistId: this.item.id, artistName: this.item.displayTitle() }
      });
      return;
    }
    if (this.item.type === 'MusicAlbum') {
      router.replaceUrl({
        url: 'pages/AlbumDetailPage',
        params: {
          albumId: this.item.id,
          albumName: this.item.displayTitle(),
          artistName: this.item.albumArtist
        }
      });
      return;
    }
    // Audio：直接播放这一首
    router.replaceUrl({
      url: 'pages/MusicPlayerPage',
      params: {
        trackIds: [this.item.id],
        trackNames: [this.item.displayTitle()],
        startIndex: 0,
        artistName: this.item.albumArtist
      }
    });
  }

  private async loadDetail(): Promise<void> {
    if (this.itemId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少 itemId';
      return;
    }
    this.status = UiState.LOADING;
    const raw: string = await JellyfinNative.getItemDetail(this.itemId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载详情失败';
      return;
    }
    this.item = MediaItem.fromJson(result.data);
    this.people = JsonUtil.getArray(result.data, 'People');

    // 音乐条目转交专用页面。
    //
    // 为什么在这里兜一道：通用详情页没有任何音乐分支（它按 Movie/Series 那套渲染
    // 海报、演职人员、剧集列表），搜索结果、收藏、播放列表等入口都会跳到本页，
    // 用户从那些地方点进专辑/艺术家时若停在这里就等于"点进去什么都没有"。
    // 用 `replaceUrl` 而不是 `pushUrl`：避免留下一个"返回后仍是空详情页"的死循环。
    if (this.item.type === 'MusicAlbum' || this.item.type === 'MusicArtist' ||
      this.item.type === 'Audio') {
      this.redirectMusic();
      return;
    }
    this.seasons = MediaItem.fromArray(JsonUtil.extractItems(JsonUtil.getObject(result.data, 'Seasons')));
    if (this.seasons.length === 0) {
      this.seasons = MediaItem.fromArray(JsonUtil.getArray(result.data, 'Seasons'));
    }
    this.similar = MediaItem.fromArray(JsonUtil.extractItems(JsonUtil.getObject(result.data, 'Similar')));
    if (this.similar.length === 0) {
      this.similar = MediaItem.fromArray(JsonUtil.getArray(result.data, 'Similar'));
    }
    this.mediaStreams = [];
    const sources: Object[] = JsonUtil.getArray(result.data, 'MediaSources');
    if (sources.length > 0) {
      const src: ESObject = sources[0] as ESObject;
      this.mediaStreams = JsonUtil.getArray(src, 'MediaStreams');
    }
    this.status = UiState.SUCCESS;
    // 剧集详情默认选中第一季并加载分集：TAB 栏一进来就该有内容，
    // 而不是"空白一片等用户自己点一下"（旧的手风琴实现就是这样）。
    if (this.item.type === 'Series' && this.seasons.length > 0) {
      await this.loadSeasonEpisodes(0);
    }
  }

  /** 选中某一季（季标签栏的点击入口）；重复点已选中的季不重新请求，避免整排剧集闪烁重建 */
  private async selectSeason(index: number): Promise<void> {
    if (index === this.activeSeasonIndex) {
      return;
    }
    await this.loadSeasonEpisodes(index);
  }

  /** 分集加载失败后的重试入口（重新请求当前季） */
  private async retrySeasonEpisodes(): Promise<void> {
    await this.loadSeasonEpisodes(this.activeSeasonIndex);
  }

  /** 加载指定季的分集 */
  private async loadSeasonEpisodes(index: number): Promise<void> {
    if (index < 0 || index >= this.seasons.length) {
      return;
    }
    this.activeSeasonIndex = index;
    this.episodes = [];
    this.episodesStatus = UiState.LOADING;
    const seq: number = ++this.episodesSeq;
    const raw: string = await JellyfinNative.getSeasonEpisodes(this.itemId, this.seasons[index].id);
    // 用户在等待期间又切了季 → 这次响应已过期，直接丢弃
    if (seq !== this.episodesSeq) {
      return;
    }
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.episodesStatus = UiState.ERROR;
      return;
    }
    this.episodes = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    this.episodesStatus = this.episodes.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  /**
   * 季标签文案。
   *
   * Jellyfin 的季名默认是英文 `Season 1`（服务器未做中文化时），而界面其余部分都是中文，
   * 直接显示很突兀。这里把 `Season N` 归一为 `第 N 季`、`Specials` 归一为 `特别篇`；
   * 其余名称（服务器自定义过季名的场景）原样显示，不擅自改写服务端数据。
   */
  private seasonTabLabel(season: MediaItem): string {
    const name: string = season.name.trim();
    if (name.length === 0) {
      return '未知季';
    }
    const prefix: string = 'season ';
    if (name.length > prefix.length && name.substring(0, prefix.length).toLowerCase() === prefix) {
      const num: string = name.substring(prefix.length).trim();
      if (this.isAllDigits(num)) {
        return `第 ${num} 季`;
      }
    }
    if (name.toLowerCase() === 'specials') {
      return '特别篇';
    }
    return name;
  }

  /** 纯数字判断（不依赖正则，避免 ArkTS 上 RegExp 的兼容差异） */
  private isAllDigits(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private async toggleFavorite(): Promise<void> {
    if (this.favoriting) return;
    this.favoriting = true;
    const next: boolean = !this.item.isFavorite;
    const raw: string = await JellyfinNative.toggleFavorite(this.item.id, next);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      this.item.isFavorite = next;
      this.showActionToast(next ? '已加入我的最爱' : '已取消收藏');
    } else {
      // 失败必须说出来：此前只在成功时更新图标，服务端 404 时用户看到的是
      // "点了星标没有任何反应"，既不知道失败也不知道为什么。
      this.showActionToast(result.message.length > 0 ? `收藏失败：${result.message}`
                                                     : '收藏失败（服务端未接受该请求）');
    }
    this.favoriting = false;
  }

  private async togglePlayed(): Promise<void> {
    const next: boolean = !this.item.isPlayed;
    const raw: string = await JellyfinNative.togglePlayed(this.item.id, next);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      this.item.isPlayed = next;
      this.showActionToast(next ? '已标记为已播放' : '已标记为未播放');
    } else {
      this.showActionToast(result.message.length > 0 ? `标记失败：${result.message}`
                                                     : '标记失败（服务端未接受该请求）');
    }
  }

  /** 操作结果用 toast 反馈（成功与失败都要可见，失败原因直接给用户看） */
  private showActionToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // toast 失败不影响状态更新本身
    }
  }

  private async openPlaylistPicker(): Promise<void> {
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.getPlaylists());
    if (!result.ok || result.data === null) {
      this.playlistItems = [];
      this.playlistMessage = result.message.length > 0 ? result.message : '加载播放列表失败';
    } else {
      this.playlistItems = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      this.playlistMessage = '';
    }
    this.sheetKind = 'playlist';
    this.sheetShow = true;
  }

  private async addToPlaylist(playlistId: string): Promise<void> {
    let result: NativeResult;
    if (playlistId.length > 0) {
      result = JellyfinNative.parseResult(await JellyfinNative.addToPlaylist(playlistId, this.item.id));
    } else {
      const name: string = this.playlistName.trim();
      if (name.length === 0) {
        this.playlistMessage = '请输入播放列表名称';
        return;
      }
      result = JellyfinNative.parseResult(await JellyfinNative.createPlaylist(name, this.item.id));
    }
    if (!result.ok) {
      this.playlistMessage = result.message.length > 0 ? result.message : '播放列表操作失败';
      return;
    }
    this.playlistName = '';
    // 添加成功后关闭弹层（参考项目：改 sheetKind/sheetShow 即可，无需手写遮罩）
    this.sheetShow = false;
  }

  /**
   * 打开弹层 —— 参考项目的做法：只设置判别字段与显示开关，
   * 弹层本体由根节点上一个 `bindSheet` 负责（不再手写遮罩、居中卡片与"点遮罩关闭"）。
   */
  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.sheetShow = true;
  }

  /**
   * 待播放条目的类型（交给播放页决定回退顺序）。
   *
   * 本页播的往往**不是**当前详情条目：剧集播的是某一集、容器（合集/季/文件夹）播的是
   * 第一个子项。因此先按 id 在已加载的分集里找，找不到再退回当前条目类型 ——
   * 剧集播出的分集类型是 `Episode`，按 `Series` 判断同样会走转码优先，两者行为一致。
   */
  private itemTypeOf(id: string): string {
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.episodes[i].id === id) {
        return this.episodes[i].type;
      }
    }
    return this.item.type;
  }

  private buildPlaybackOptions(): string {
    const opts: Record<string, Object> = {
      'audioStreamIndex': this.audioStreamIndex,
      'subtitleStreamIndex': this.subtitleStreamIndex,
      'enableDirectPlay': !this.forceTranscode,
      'enableDirectStream': !this.forceTranscode,
      'enableTranscoding': true
    };
    return JSON.stringify(opts);
  }

  /**
   * 交给播放页播放某个条目。
   *
   * `startPositionMs`：该条目的观看进度（`PlaybackPositionTicks` 是 100ns 单位）。
   * 传下去后播放器会在 `prepared` 之后 seek 到该位置 —— 否则「继续播放」等于从头再来，
   * 而"继续观看/进度条"也就名不副实。
   */
  private playItem(id: string, startPositionMs: number = 0): void {
    const resumeMs: number = startPositionMs > 1000 ? startPositionMs
                                                    : this.resumeMsForItem(id);
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: {
        itemId: id,
        // 播放页据此决定"硬解失败后是否先让服务器转码"（见 PlayerPage.prefersServerTranscode）：
        // 电影/剧集优先转码，其余类型沿用直连→软解。
        itemType: this.itemTypeOf(id),
        title: this.item.name,
        playbackOptions: this.buildPlaybackOptions(),
        startPositionMs: resumeMs,
        // 把可切换的流列表带给播放页，使其能在**播放中**切换音频/字幕
        // （Jellyfin 的轨道选择是 PlaybackInfo 参数，切换后按原位置重新拉起播放即可，
        //   对硬解与软解两条路径都成立）
        mediaStreams: JSON.stringify(this.mediaStreams)
      }
    });
  }

  /** 该条目（或它的第一集）的续播位置（毫秒）；没有进度时返回 0 */
  /**
   * 主播放按钮文案。
   *
   * 有观看进度时显示「继续播放 · mm:ss」：既说明会从上次位置接着播，
   * 也把"上次看到哪儿"直接告诉用户（此前只有进度条，按钮永远写"播放"，点了却从头开始）。
   */
  private playButtonLabel(): string {
    const resumeMs: number = Math.floor(this.item.playbackPositionTicks / 10000);
    const compact: boolean = this.item.type === 'Series' || this.item.type === 'Episode';
    if (resumeMs > 1000) {
      // 剧集类按钮是固定宽度（150vp），带上时间会被裁掉，因此只在整行按钮上显示时间
      return compact ? '继续播放'
                     : `继续播放 · ${formatTicks(this.item.playbackPositionTicks)}`;
    }
    // 剧集（Series）按钮点下去播的是**当前选中季的第一集**（见 `startPlayback`），
    // 说成"本集"并不成立（详情页没有"当前集"这个概念）；单集（Episode）才是真的本集。
    if (this.item.type === 'Series') {
      return '播放';
    }
    return compact ? '播放本集' : '播放';
  }

  private resumeMsForItem(id: string): number {
    if (id === this.item.id) {
      return Math.floor(this.item.playbackPositionTicks / 10000);
    }
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.episodes[i].id === id) {
        return Math.floor(this.episodes[i].playbackPositionTicks / 10000);
      }
    }
    return 0;
  }

  /**
   * 播放动作统一入口。
   *
   * 剧集（Series）**不能直接播放**：设备实测服务端对 `/Items/{seriesId}/PlaybackInfo`
   * 返回 **HTTP 500**（同一服务器对剧集条目 `/Items/{episodeId}/PlaybackInfo` 返回 200 并给出播放地址）。
   * 因此这里先解析出"第一季第一集"再交给播放器，与各 Jellyfin 客户端的行为一致。
   */
  private async startPlayback(): Promise<void> {
    if (this.item.type === 'Series') {
      // 优先播"当前选中那一季的第一集"：用户在第 3 季标签下按播放，播的应该是第 3 季，
      // 而不是被跳回第 1 季（旧实现固定取 `seasons[0]`，与界面上选中的季无关）。
      if (this.episodes.length > 0) {
        this.playItem(this.episodes[0].id);
        return;
      }
      if (this.seasons.length === 0) {
        this.errorMsg = '该剧集暂无可播放的分集';
        return;
      }
      const raw: string = await JellyfinNative.getSeasonEpisodes(this.item.id, this.seasons[0].id);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok) {
        this.errorMsg = result.message.length > 0 ? result.message : '加载分集失败';
        return;
      }
      const episodes: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      if (episodes.length === 0) {
        this.errorMsg = '该剧集暂无可播放的分集';
        return;
      }
      this.playItem(episodes[0].id);
      return;
    }
    // 容器类条目（合集/播放列表/季/文件夹）**本身不是可播放媒体**：
    // 直接拿它的 id 去请求播放信息必然失败（与剧集同因）。
    // 这里解析出"第一个可播放子项"再交给播放器，与各 Jellyfin 客户端行为一致。
    if (this.item.type === 'BoxSet' || this.item.type === 'Playlist' ||
        this.item.type === 'Season' || this.item.type === 'Folder' || this.item.isFolder) {
      const firstId: string = await this.resolveFirstPlayableChild();
      if (firstId.length === 0) {
        this.errorMsg = '该条目暂无可播放的内容';
        return;
      }
      this.playItem(firstId);
      return;
    }
    this.playItem(this.item.id);
  }

  /** 取容器条目的第一个可播放子项 id；取不到返回空串 */
  private async resolveFirstPlayableChild(): Promise<string> {
    if (this.item.type === 'Playlist') {
      const raw: string = await JellyfinNative.getPlaylistItems(this.item.id, 0, 1);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok) {
        return '';
      }
      const items: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      return items.length > 0 ? items[0].id : '';
    }
    // 季 → 分集；合集/文件夹 → 任意可播放子项（按名称排序取第一个）
    const query: Record<string, Object> = {
      'parentId': this.item.id,
      'startIndex': 0,
      'limit': 1,
      'recursive': true,
      'sortBy': 'SortName',
      'sortOrder': 'Ascending',
      'includeItemTypes': this.item.type === 'Season' ? 'Episode' : ''
    };
    const raw: string = await JellyfinNative.queryItems(JSON.stringify(query));
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      return '';
    }
    const items: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    return items.length > 0 ? items[0].id : '';
  }

  private mediaInfoLabels(): string[] {
    const info: string[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const stream: ESObject = this.mediaStreams[i] as ESObject;
      const type: string = JsonUtil.getString(stream, 'Type', '').toLowerCase();
      const codec: string = JsonUtil.getString(stream, 'Codec', '');
      const width: number = JsonUtil.getNumber(stream, 'Width', 0);
      const height: number = JsonUtil.getNumber(stream, 'Height', 0);
      const bitRate: number = JsonUtil.getNumber(stream, 'BitRate', 0);
      if (type === 'video' && width > 0 && height > 0 && info.indexOf(`${width}x${height}`) < 0) {
        info.push(`${width}x${height}`);
      }
      if (codec.length > 0 && info.indexOf(codec.toUpperCase()) < 0) {
        info.push(codec.toUpperCase());
      }
      if (type === 'video' && bitRate > 0) {
        const rate: string = `${(bitRate / 1000000).toFixed(1)} Mbps`;
        if (info.indexOf(rate) < 0) {
          info.push(rate);
        }
      }
    }
    return info.slice(0, 6);
  }

  private personId(person: Object): string {
    return JsonUtil.itemId(person);
  }

  private personName(person: Object): string {
    const name: string = JsonUtil.itemName(person);
    return name.length > 0 ? name : '\u672a\u77e5';
  }

  /**
   * 演职人员头像 URL。
   *
   * **必须解析 `getImageUrl` 的返回值**：该桥接返回的是 JSON 信封
   * `{"ok":true,"status":200,"message":"ok","data":{"url":"…"}}`，不是裸 URL。
   * 早期实现写成 `return JellyfinNative.getImageUrl(...).trim()` —— 把整串 JSON
   * 当 URL 传给 `JellyfinImage`，取图必然失败，于是演员位只显示占位人形图标。
   * （海报/背景图走 `MediaItem.imageUrl()`，那里一直是 parseResult 后取 `data.url`，
   * 所以只有详情页的演员头像坏。）
   *
   * 服务端侧已排除：`People[].PrimaryImageTag` 有值，且
   * `GET /Items/{personId}/Images/Primary` 返回 200 image/jpeg。
   */
  private personImageUrl(person: Object): string {
    const id: string = this.personId(person);
    if (id.length === 0) {
      return '';
    }
    const tag: string = JsonUtil.getString(person as ESObject, 'PrimaryImageTag', '');
    const raw: string = JellyfinNative.getImageUrl(id, 'Primary', 200, tag);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      return '';
    }
    return JsonUtil.getString(result.data as ESObject, 'url', '');
  }

  private openPerson(person: Object): void {
    const id: string = this.personId(person);
    if (id.length > 0) {
      // 一并带上姓名：人物页直接用这个名字渲染头部，
      // 无需请求 /Users/{uid}/Items/{personId}（实测部分 Jellyfin 版本对该端点会挂起不响应）
      router.pushUrl({
        url: 'pages/PersonPage',
        params: { personId: id, personName: this.personName(person) }
      });
    }
  }

  /** 按类型取媒体流（与播放页 `streamsOfType` 同一口径） */
  private streamsOfType(type: string): Object[] {
    const out: Object[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const s: ESObject = this.mediaStreams[i] as ESObject;
      if (JsonUtil.getString(s, 'Type', '') === type) {
        out.push(this.mediaStreams[i]);
      }
    }
    return out;
  }

  private audioStreams(): Object[] {
    return this.streamsOfType('Audio');
  }

  private subtitleStreams(): Object[] {
    return this.streamsOfType('Subtitle');
  }

  /** 下拉项下标 → 媒体流真实 Index（下标 0 固定是「未选择」，不参与映射） */
  private streamIndexAt(list: Object[], optionIndex: number): number {
    if (optionIndex < 0 || optionIndex >= list.length) {
      return -1;
    }
    return JsonUtil.getNumber(list[optionIndex] as ESObject, 'Index', -1);
  }

  /** 当前选中的流在下拉里的位置（0 = 未选择） */
  private optionIndexOf(list: Object[], streamIndex: number): number {
    if (streamIndex < 0) {
      return 0;
    }
    for (let i = 0; i < list.length; i++) {
      if (JsonUtil.getNumber(list[i] as ESObject, 'Index', -1) === streamIndex) {
        return i + 1;
      }
    }
    return 0;
  }

  /** 下拉项标题：DisplayTitle 优先，缺失时退回 `Audio 1` / `Subtitle 2` 这类可读文本 */
  private streamOptionValue(stream: ESObject, kind: string): string {
    const displayTitle: string = JsonUtil.getString(stream, 'DisplayTitle',
      JsonUtil.getString(stream, 'Language', ''));
    if (displayTitle.length > 0) {
      return displayTitle;
    }
    return `${kind} ${JsonUtil.getNumber(stream, 'Index', -1)}`;
  }

  /**
   * 「音频」下拉：第 0 项固定「未选择」（不指定音轨，服务端按默认音轨起播），
   * 之后只列 Audio 流 —— 此前把视频流、字幕流也一并列了出来，
   * 与播放页按 `streamsOfType('Audio')` 取轨的口径不一致。
   */
  private audioOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: TRACK_UNSELECTED }];
    const list: Object[] = this.audioStreams();
    for (let i = 0; i < list.length; i++) {
      options.push({ value: this.streamOptionValue(list[i] as ESObject, 'Audio') });
    }
    return options;
  }

  /** 「字幕」下拉：第 0 项「未选择」取代原来的「关闭」（两者含义同为不指定字幕轨） */
  private subtitleOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: TRACK_UNSELECTED }];
    const list: Object[] = this.subtitleStreams();
    for (let i = 0; i < list.length; i++) {
      options.push({ value: this.streamOptionValue(list[i] as ESObject, 'Subtitle') });
    }
    return options;
  }

  /**
   * 关闭态按钮上的文字。
   *
   * 注意：`Select` 的 `.selected(n)` 只决定"选中第几项"，按钮上显示的文本由 `.value()` 给定
   * （SDK：value "Sets the text display of the select button itself"）。不设 `.value()` 时按钮是空的，
   * 于是"未选择"这个状态在界面上完全看不出来。
   */
  private audioOptionText(): string {
    const list: Object[] = this.audioStreams();
    const index: number = this.optionIndexOf(list, this.audioStreamIndex);
    return index === 0 ? TRACK_UNSELECTED
                       : this.streamOptionValue(list[index - 1] as ESObject, 'Audio');
  }

  private subtitleOptionText(): string {
    const list: Object[] = this.subtitleStreams();
    const index: number = this.optionIndexOf(list, this.subtitleStreamIndex);
    return index === 0 ? TRACK_UNSELECTED
                       : this.streamOptionValue(list[index - 1] as ESObject, 'Subtitle');
  }

  /** 构建媒体信息行 */
  @Builder
  MediaInfoRow() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.mediaInfoLabels(), (text: string) => {
        Text(text)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.colors().surfacePressed)
          .borderRadius(8)
          .margin({ right: 8, bottom: 4 })
      }, (text: string) => text)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  /** 流信息描述文本 */
  private streamsSummary(): string {
    return this.mediaStreams.length > 0
      ? `${this.mediaStreams.length} 条媒体流`
      : '无媒体流信息';
  }

  /** 流条目数据结构 */
  private streamEntries(): StreamEntry[] {
    const entries: StreamEntry[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const s: ESObject = this.mediaStreams[i] as ESObject;
      const type: string = JsonUtil.getString(s, 'Type', '');
      const codec: string = JsonUtil.getString(s, 'Codec', '');
      const w: number = JsonUtil.getNumber(s, 'Width', 0);
      const h: number = JsonUtil.getNumber(s, 'Height', 0);
      const sizeLabel: string = (w > 0 && h > 0) ? `${w}x${h}` : '';
      entries.push({ type, codec, sizeLabel });
    }
    return entries;
  }

  /**
   * 详情页统一弹层 —— 参考项目「一个 bindSheet 节点 + sheetKind 判别」：
   * 通过 `sheetKind` 决定渲染哪一份内容，取代原来 4 套手写全屏遮罩。
   */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'playOptions') {
      this.PlayOptionsSheet()
    } else if (this.sheetKind === 'mediaInfo') {
      this.MediaInfoDialog()
    } else if (this.sheetKind === 'markPlayed') {
      this.MarkPlayedSheet()
    } else if (this.sheetKind === 'playlist') {
      this.PlaylistSheet()
    }
  }

  /** 播放选项（强制转码 / 媒体信息 / 加入播放列表） */
  @Builder
  PlayOptionsSheet() {
    Column({ space: 8 }) {
      Text('\u64ad\u653e\u9009\u9879')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Row() {
        Column({ space: 2 }) {
          Text('\u5f3a\u5236\u8f6c\u7801\u64ad\u653e')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().textPrimary)
          Text('\u4e0d\u8d70\u76f4\u63a5\u64ad\u653e\uff0c\u7531\u670d\u52a1\u5668\u8f6c\u7801\u540e\u64ad\u653e')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.forceTranscode })
          .selectedColor(this.colors().brandPrimary)
          .onChange((on: boolean) => {
            this.forceTranscode = on;
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      SecondaryButton({
        label: '\u5a92\u4f53\u4fe1\u606f',
        onTap: () => {
          this.sheetKind = 'mediaInfo';
        }
      })
      SecondaryButton({
        label: '\u52a0\u5165\u64ad\u653e\u5217\u8868',
        onTap: () => {
          this.openPlaylistPicker();
        }
      })
      TextButton({
        label: '\u5173\u95ed',
        onTap: () => {
          this.sheetShow = false;
        }
      })
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 标记已播放/未播放确认 */
  @Builder
  MarkPlayedSheet() {
    Column({ space: 8 }) {
      Text(this.item.isPlayed ? $r('app.string.play_mark_unplayed') : $r('app.string.play_mark_played'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Text(this.item.isPlayed ? '\u786e\u8ba4\u6807\u8bb0\u4e3a\u672a\u64ad\u653e\uff1f' : '\u786e\u8ba4\u6807\u8bb0\u4e3a\u5df2\u64ad\u653e\uff1f')
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .margin({ bottom: 8 })
      PrimaryButton({
        label: this.item.isPlayed ? $r('app.string.play_mark_unplayed') : $r('app.string.play_mark_played'),
        onTap: () => {
          this.togglePlayed();
          this.sheetShow = false;
        }
      })
      TextButton({
        label: '\u53d6\u6d88',
        onTap: () => {
          this.sheetShow = false;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 加入播放列表（新建 + 选择已有） */
  @Builder
  PlaylistSheet() {
    Column({ space: 8 }) {
      Text('\u52a0\u5165\u64ad\u653e\u5217\u8868')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      TextInput({ text: this.playlistName, placeholder: '\u65b0\u5efa\u64ad\u653e\u5217\u8868\u540d\u79f0' })
        .width('100%')
        .height(ThemeConstants.INPUT_HEIGHT)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .backgroundColor(this.colors().pageBackground)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.COVER_RADIUS })
        .onChange((value: string) => {
          this.playlistName = value;
        })
      if (this.playlistMessage.length > 0) {
        Text(this.playlistMessage)
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
      }
      PrimaryButton({
        label: '\u65b0\u5efa\u5e76\u6dfb\u52a0',
        onTap: () => {
          this.addToPlaylist('');
        }
      })
      if (this.playlistItems.length > 0) {
        List({ space: 4 }) {
          ForEach(this.playlistItems, (playlist: MediaItem) => {
            ListItem() {
              Text(playlist.name)
                .width('100%')
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .padding({ top: 10, bottom: 10 })
                .onClick(() => {
                  this.addToPlaylist(playlist.id);
                })
            }
          }, (playlist: MediaItem) => playlist.id)
        }
        .width('100%')
        .height(Math.min(180, this.playlistItems.length * 44))
        .scrollBar(BarState.Auto)
      }
      TextButton({
        label: '\u53d6\u6d88',
        onTap: () => {
          this.sheetShow = false;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 完整媒体流信息（作为 sheet 内容渲染，不再自带遮罩与卡片外壳） */
  @Builder
  MediaInfoDialog() {
    Column({ space: 8 }) {
      Text($r('app.string.media_info_title'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Text(this.streamsSummary())
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
      List({ space: 4 }) {
        ForEach(this.streamEntries(), (entry: StreamEntry) => {
          ListItem() {
            Row() {
              Text(entry.type)
                .fontSize(ThemeConstants.BADGE_LABEL)
                .fontColor(this.colors().brandPrimary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(this.colors().surfacePressed)
                .borderRadius(5)
              Text(entry.codec)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textPrimary)
                .margin({ left: 8 })
              Text(entry.sizeLabel)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(entry.sizeLabel.length > 0 ? this.colors().textSecondary : Color.Transparent)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          }
        }, (_: StreamEntry, idx: number) => `${idx}`)
      }
      .width('100%')
      .height(200)
      .scrollBar(BarState.Auto)
      TextButton({
        label: '\u5173\u95ed',
        onTap: () => {
          this.sheetShow = false;
        }
      })
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 季标签栏（横向可滚动）。
   *
   * 用横向 `List` 而不是 `Row() + ForEach`：季数多的剧（20+ 季）在 `Row` 里会被挤到
   * 每季只剩几个字，`List` 则可以滑动。选中态 = 品牌色文字 + 品牌色下划线。
   */
  @Builder
  SeasonTabs() {
    List({ space: 14 }) {
      ForEach(this.seasons, (season: MediaItem, index: number) => {
        ListItem() {
          Column({ space: 4 }) {
            Text(this.seasonTabLabel(season))
              .fontSize(ThemeConstants.META_MEDIUM)
              .fontWeight(index === this.activeSeasonIndex ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(index === this.activeSeasonIndex
                ? this.colors().brandPrimary
                : this.colors().textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 选中下划线：未选中用透明色占位，保证所有标签高度一致、不会因选中而跳动
            Row()
              .width(24)
              .height(2)
              .borderRadius(1)
              .backgroundColor(index === this.activeSeasonIndex
                ? this.colors().brandPrimary
                : Color.Transparent)
          }
          .height(SEASON_TABS_HEIGHT)
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            this.selectSeason(index);
          })
        }
      }, (season: MediaItem, index: number) => `${season.id}_${index}`)
    }
    .listDirection(Axis.Horizontal)
    .scrollBar(BarState.Off)
    .height(SEASON_TABS_HEIGHT)
    .padding({ left: 16, right: 16 })
    .width('100%')
  }

  /** 演职人员横滑 */
  @Builder
  PeopleRow(people: Object[]) {
    Column() {
      Text('\u6f14\u804c\u4eba\u5458')
        .fontSize(ThemeConstants.TITLE_SMALL)
        .fontColor(this.colors().textPrimary)
        .padding({ left: 16, top: 8, bottom: 8 })
        .width('100%')
      List({ space: 12 }) {
        ForEach(people, (p: Object) => {
          ListItem() {
            Column({ space: 4 }) {
              JellyfinImage({
                url: this.personImageUrl(p),
                imgWidth: 72,
                imgHeight: 72,
                cornerRadius: 36,
                placeholderIcon: 'person'
              })
              Text(this.personName(p))
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textPrimary)
                .maxLines(1)
                .width(72)
                .textAlign(TextAlign.Center)
            }
            .width(72)
            .onClick(() => {
              this.openPerson(p);
            })
          }
        }, (p: Object, index: number) => `${this.personId(p)}_${index}`)
      }
      .listDirection(Axis.Horizontal)
      .height(110)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
      // 横向 List 的宽度默认随内容自适应：演职人员少时整排会缩成内容宽，
      // 再被外层 Column 的默认居中排到屏幕中间。这里显式占满宽度，
      // 让第一位始终贴 16vp 左边界（与海报/简介/标题以及货架列表一致）。
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      if (this.status !== UiState.SUCCESS) {
        Column() {
          PageHeader({
            title: '\u8be6\u60c5',
            onBack: () => {
              router.back();
            }
          })
          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
            LoadingState()
          } else if (this.status === UiState.ERROR) {
            EmptyState({
              message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
              actionLabel: '重试',
              onAction: () => {
                this.loadDetail();
              }
            })
          } else if (this.status === UiState.EMPTY) {
            EmptyState({ message: '暂无数据' })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().pageBackground)
      } else {
        Scroll() {
          Column() {
            // 顶部背景横幅（BackdropBanner）
            Stack({ alignContent: Alignment.TopStart }) {
              // 与页面其余封面一致，经 JellyfinImage 取图：避免 Image(远程URL) 走 ArkUI
              // 自带网络栈（大图库下 fd 逼近上限会 abort），也避免把请求 URL 交给外部组件。
              JellyfinImage({
                url: this.item.imageUrl(900, 'Backdrop'),
                fillMode: true
              })
                .width('100%')
                .height(180)
              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 180,
                  colors: [[this.colors().posterScrim, 0.0], [this.colors().pageBackground, 1.0]]
                })
            }
            .width('100%')
            .height(180)

            PageHeader({
              title: '',
              onBack: () => {
                router.back();
              }
            })

            // 海报 + 信息区
            Row({ space: 16 }) {
              JellyfinImage({
                url: this.item.imageUrl(600, 'Primary'),
                imgWidth: ThemeConstants.DETAIL_POSTER_WIDTH,
                imgHeight: ThemeConstants.DETAIL_POSTER_HEIGHT,
                cornerRadius: ThemeConstants.POSTER_RADIUS
              })
              Column({ space: 8 }) {
                Text(this.item.name)
                  .fontSize(ThemeConstants.TITLE_LARGE)
                  .fontColor(this.colors().textPrimary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.item.metaLine())
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  if (this.item.type.length > 0) {
                    Text(this.item.typeLabel())
                      .fontSize(ThemeConstants.LABEL_SMALL)
                      .fontColor(this.colors().textPrimary)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .backgroundColor(this.colors().surfacePressed)
                      .borderRadius(8)
                      .margin({ right: 8, bottom: 4 })
                  }
                  ForEach(this.item.genres.slice(0, 3), (genre: string) => {
                    Text(genre)
                      .fontSize(ThemeConstants.LABEL_SMALL)
                      .fontColor(this.colors().textPrimary)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .backgroundColor(this.colors().surfacePressed)
                      .borderRadius(8)
                      .margin({ right: 8, bottom: 4 })
                  }, (genre: string) => genre)
                }
                .width('100%')
                // 播放按钮行 —— 主操作按参考项目规格（48vp / 12vp 圆角 / 品牌实底 + 微光投影），
                // 其余操作用 40vp 圆形图标按钮 + 系统符号（原来用的是 ▼ ★ ⏱ ⋮ 文本字符）
                Flex({ wrap: FlexWrap.Wrap }) {
                  Button(this.playButtonLabel(),
                    { type: ButtonType.Normal, stateEffect: false })
                    .height(ThemeConstants.BUTTON_HEIGHT)
                    .width(this.item.type === 'Series' || this.item.type === 'Episode' ? 150 : '100%')
                    .fontSize(ThemeConstants.TITLE_MEDIUM)
                    .fontWeight(FontWeight.Medium)
                    .backgroundColor(this.colors().brandPrimary)
                    .fontColor(this.colors().onBrand)
                    .borderRadius(ThemeConstants.BUTTON_RADIUS)
                    .shadow({
                      radius: 10,
                      color: this.colors().buttonShadow,
                      offsetX: 0,
                      offsetY: 4
                    })
                    .stateStyles({
                      pressed: {
                        .backgroundColor(this.colors().brandPrimaryPressed)
                      }
                    })
                    .margin({ right: 4, bottom: 4 })
                    .onClick(() => {
                      // 走统一入口：剧集会先解析分集（系列条目本身无法直接播放）
                      this.startPlayback();
                    })
                  AppIconButton({
                    icon: $r('sys.symbol.chevron_down'),
                    variant: 'surface',
                    iconSize: 18,
                    onTap: () => {
                      this.openSheet('playOptions');
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  AppIconButton({
                    icon: this.item.isFavorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
                    variant: this.item.isFavorite ? 'soft' : 'surface',
                    iconSize: 19,
                    onTap: () => {
                      this.toggleFavorite();
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  AppIconButton({
                    icon: $r('sys.symbol.clock'),
                    variant: 'surface',
                    iconSize: 18,
                    iconColorOverride: this.item.isPlayed ? this.colors().success : '',
                    onTap: () => {
                      this.openSheet('markPlayed');
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  if (AppViewModel.getInstance().isAdmin) {
                    AppIconButton({
                      icon: $r('sys.symbol.doc_text'),
                      variant: 'surface',
                      iconSize: 18,
                      onTap: () => {
                        this.openMetadataEditor();
                      }
                    })
                      .margin({ right: 4, bottom: 4 })
                  }
                  AppIconButton({
                    icon: $r('sys.symbol.ellipsis_circle'),
                    variant: 'surface',
                    iconSize: 18,
                    onTap: () => {
                      // 更多菜单：直接打开媒体信息弹层
                      this.openSheet('mediaInfo');
                    }
                  })
                    .margin({ bottom: 4 })
                }
                .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 4 })

            // 音频/字幕选择器（如果有多个音轨或字幕轨）
            if (this.mediaStreams.length > 1) {
              Column() {
                Text('\u97f3\u9891 / \u5b57\u5e55')
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                  .padding({ left: 16, bottom: 4 })
                  .width('100%')
                Row({ space: 12 }) {
                  // 音频轨选择（未选择 = 不指定音轨，由服务端用默认音轨）
                  Select(this.audioOptions())
                    .value(this.audioOptionText())
                    .selected(this.optionIndexOf(this.audioStreams(), this.audioStreamIndex))
                    .backgroundColor(this.colors().surfacePressed)
                    .fontColor(this.colors().textPrimary)
                    .height(40)
                    .layoutWeight(1)
                    .border({ width: 1, color: this.colors().divider, radius: 4 })
                    .padding({ left: 12, right: 12 })
                    .onSelect((index: number, _value: string) => {
                      this.audioStreamIndex = index === 0
                        ? -1
                        : this.streamIndexAt(this.audioStreams(), index - 1);
                    })
                  // 字幕轨选择（未选择 = 不指定字幕轨，由服务端决定）
                  Select(this.subtitleOptions())
                    .value(this.subtitleOptionText())
                    .selected(this.optionIndexOf(this.subtitleStreams(), this.subtitleStreamIndex))
                    .backgroundColor(this.colors().surfacePressed)
                    .fontColor(this.colors().textPrimary)
                    .height(40)
                    .layoutWeight(1)
                    .border({ width: 1, color: this.colors().divider, radius: 4 })
                    .padding({ left: 12, right: 12 })
                    .onSelect((index: number, _value: string) => {
                      this.subtitleStreamIndex = index === 0
                        ? -1
                        : this.streamIndexAt(this.subtitleStreams(), index - 1);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 8 })
              }
              .width('100%')
            }

            // 简介
            if (this.item.overview.length > 0) {
              Text(this.item.overview)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .lineHeight(22)
                .padding({ left: 16, right: 16, top: 4, bottom: 16 })
                .width('100%')
            }

            // 演职人员
            if (this.people.length > 0) {
              this.PeopleRow(this.people)
            }

            // 媒体信息
            if (this.mediaInfoLabels().length > 0) {
              this.MediaInfoRow();
            }

            // 季-集浏览（Series 类型）：季用 TAB 切换，分集横向排列
            if (this.item.type === 'Series' && this.seasons.length > 0) {
              Column() {
                Text('\u5b63\u4e0e\u96c6')
                  .fontSize(ThemeConstants.TITLE_SMALL)
                  .fontColor(this.colors().textPrimary)
                  .padding({ left: 16, top: 8, bottom: 4 })
                  .width('100%')

                this.SeasonTabs()

                if (this.episodesStatus === UiState.LOADING) {
                  Row() {
                    LoadingProgress()
                      .width(28)
                      .height(28)
                      .color(this.colors().brandPrimary)
                  }
                  .width('100%')
                  .height(EPISODE_SHELF_HEIGHT)
                  .justifyContent(FlexAlign.Center)
                } else if (this.episodes.length === 0) {
                  Row() {
                    Text(this.episodesStatus === UiState.ERROR
                      ? '\u5206\u96c6\u52a0\u8f7d\u5931\u8d25\uff0c\u70b9\u51fb\u91cd\u8bd5'
                      : '\u672c\u5b63\u6682\u65e0\u53ef\u64ad\u653e\u7684\u5206\u96c6')
                      .fontSize(ThemeConstants.META_SMALL)
                      .fontColor(this.episodesStatus === UiState.ERROR
                        ? this.colors().brandPrimary
                        : this.colors().textTertiary)
                  }
                  .width('100%')
                  .height(EPISODE_SHELF_HEIGHT)
                  .justifyContent(FlexAlign.Center)
                  .onClick(() => {
                    // 只有"加载失败"值得重试；"本季没有分集"重试也不会有变化
                    if (this.episodesStatus === UiState.ERROR) {
                      this.retrySeasonEpisodes();
                    }
                  })
                } else {
                  List({ space: ThemeConstants.CARD_GAP }) {
                    ForEach(this.episodes, (ep: MediaItem) => {
                      ListItem() {
                        EpisodeCard({
                          item: ep,
                          cardWidth: EPISODE_CARD_WIDTH,
                          onTap: (target: MediaItem) => {
                            this.playItem(target.id);
                          }
                        })
                      }
                    }, (ep: MediaItem) => `${ep.id}_${ep.isPlayed ? 1 : 0}`)
                  }
                  .listDirection(Axis.Horizontal)
                  .scrollBar(BarState.Off)
                  .height(EPISODE_SHELF_HEIGHT)
                  .padding({ left: 16, right: 16 })
                  .width('100%')
                }
              }
              .width('100%')
              .padding({ bottom: 8 })
            }

            // 相关推荐
            if ((this.item.type === 'Movie' || this.item.type === 'Series') && this.similar.length > 0) {
              HorizontalShelf({
                title: '\u76f8\u4f3c\u63a8\u8350',
                icon: '',
                items: this.similar,
                shelfHeight: 235,
                onItemTap: (it: MediaItem) => {
                  router.pushUrl({ url: 'pages/DetailPage', params: { itemId: it.id } });
                }
              })
            }
          }
          .width('100%')
          .padding({ bottom: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }

      // 所有弹层统一由根节点的 bindSheet + sheetKind 承载（见文件末尾），
      // 原来这里的 4 套「全屏遮罩 + 居中卡片 + 点遮罩关闭」已删除
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    .bindSheet($$this.sheetShow, this.SheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      backgroundColor: this.colors().cardBackground,
      onDisappear: () => {
        // 关闭后清空判别字段，下次打开时不会残留上次的内容
        this.sheetKind = '';
      }
    })
  }
}
