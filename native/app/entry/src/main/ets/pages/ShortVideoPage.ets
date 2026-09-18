import router from '@ohos.router';
import media from '@ohos.multimedia.media';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PlaybackState } from '../common/PlaybackState';
import { kScaleTypeFitCrop } from '../common/PlayerAspect';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { MediaItem } from '../models/MediaItem';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { ShortVideoPrefs, kShortVideoBatchSize } from '../common/ShortVideoPrefs';
import { JellyfinImage } from '../components/JellyfinImage';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';

/** 「视频」页在外壳底部页签中的下标（MainShell：媒体库 / 视频 / 设置） */
const kVideoTabIndex: number = 1;

/**
 * 「视频」页 —— 短视频模式的承载页（底部导航第三个页签）。
 *
 * 为什么单独做一个导航页而不是塞进媒体库页：
 * 短视频的心智是"打开就刷"，与"进库 → 找片子 → 进详情 → 播放"是两条完全不同的动线；
 * 混在一个页面里会让两侧都变复杂。这里只做一件事：把**设置里勾选的短视频媒体库**
 * 随机抽出来，竖屏满屏逐条呈现，上下滑动切换（本轮先做到"浏览 + 点播"，
 * 页内自动连播在后续迭代里接）。
 *
 * 与媒体库页的关系：媒体库页是"按库/按类型浏览"，这里是"跨库随机流"，
 * 因此它不需要自己的 PageHeader（外壳 `MainShell` 已提供顶栏）。
 */
/**
 * 单条播放失败后自动跳过下一条的等待时间（毫秒）。
 *
 * 短视频流的体验前提是"一直在放"：某一条硬解不支持（如模拟器上的 HEVC）、
 * 或取流失败时，停在原地等用户点一下就等于流程断了。因此如实提示 4 秒后自动跳过，
 * 同时给出「软解播放」入口（那条内容并非不可看，只是本机硬解解不了）。
 */
const kAutoSkipMs: number = 4000;

/** 进度上报节流（与播放页一致：5 秒一次 + 关键节点补发） */
const kReportIntervalMs: number = 5000;

@Component
export struct ShortVideoPage {
  @Link themeTick: number;
  /**
   * 外壳传来的"重读配置"信号（切到「视频」页签时自增）。
   *
   * 见 `MainShell.videoTabTick` 的说明：本页是从设置页返回后**不会重建**的嵌入式组件，
   * 只能靠外部信号触发重读。
   */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /** 是否嵌在外壳里（当前恒为 true；保留参数便于以后单独路由打开） */
  @Prop embedded: boolean = true;
  /** 外壳当前页签下标：非「视频」页时暂停播放（见 onTabIndexChanged） */
  @Prop @Watch('onTabIndexChanged') activeTab: number = kVideoTabIndex;
  /**
   * 沉浸式全屏下工具层要避让的顶部像素（vp）。
   *
   * 「视频」页默认全屏沉浸式：**画面铺满整屏**，但工具栏/标题不能被挖孔或状态栏压住，
   * 因此只有叠在画面上的那一层按这个值内缩。
   */
  @Prop topInsetVp: number = 0;

  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private currentIndex: number = 0;
  /** 已选媒体库的名称（用于顶部说明"内容来自哪儿"；id 才是配置，名称只用于展示） */
  @State private libraryNames: string[] = [];
  @State private refreshing: boolean = false;
  /** 本次取数所用的媒体库选择（用于判断"切回本页时配置是否变了"） */
  private loadedLibraryIds: string[] = [];

  // ─────────────────────────── 页内播放（短视频的核心）───────────────────────────
  //
  // 为什么必须页内播放而不是"点一下跳播放页"：短视频的心智是**连续**刷 ——
  // 每条都要退回上一页再点开，动线立刻就断了。这里给「视频」页自己一个
  // XComponent + AVPlayer：滑到哪条就自动播哪条，播完自动下一条，单击暂停/继续。
  // 硬解不支持的内容不在本页硬扛（软解要 EGL + 原生桥，播放页才是它的家）：
  // 如实提示并给「软解播放」入口，4 秒后自动跳过。
  /** XComponent 控制器：surface 就绪后取 surfaceId 交给 AVPlayer */
  private surfaceController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private avPlayer: media.AVPlayer | null = null;
  /** 当前正在播的条目 id（用于切换时补发 stopped，避免服务端会话堆积） */
  private playingItemId: string = '';
  @State private videoReady: boolean = false;
  @State private paused: boolean = false;
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  /** 当前条目播放失败的原因（非空即显示失败浮层 + 自动跳过倒计时） */
  @State private playbackError: string = '';
  /** 是否已滑到列表末尾（末尾不再自动循环，给"换一批"入口） */
  @State private reachedEnd: boolean = false;
  private progressTimerId: number = -1;
  /** 当前这次暂停是否由"切走页签"造成（决定切回时是否自动续播） */
  private pausedByTabSwitch: boolean = false;
  private skipTimerId: number = -1;
  private lastReportAt: number = 0;

  aboutToAppear(): void {
    this.loadFeed();
  }

  aboutToDisappear(): void {
    this.stopProgressTicker();
    this.cancelAutoSkip();
    this.releasePlayer();
  }

  /**
   * 外壳页签变化：离开「视频」页就暂停播放。
   *
   * 为什么必须处理：本页是嵌入式组件，切到"设置"页签时它**不会销毁** ——
   * 不暂停的话用户会在设置页里听到短视频的声音（而且看不见画面，无从暂停）。
   */
  onTabIndexChanged(): void {
    if (this.activeTab !== kVideoTabIndex) {
      // 只对"因切页签而暂停"做标记：用户自己按暂停的，切回来不该被自动续播
      if (this.avPlayer !== null && !this.paused) {
        this.pausePlayback();
        this.pausedByTabSwitch = true;
      }
      return;
    }
    // 切回本页：续播（`play()`，**不是** `playCurrent()` —— 后者会从头重开这一条）
    if (this.pausedByTabSwitch && this.avPlayer !== null) {
      this.pausedByTabSwitch = false;
      try {
        this.avPlayer.play();
      } catch (err) {
        // 播放器可能已不可用：下一次滑动会重建
      }
    }
  }

  /**
   * 外部信号（切到本页签）：只在**配置真的变了**或当前没有内容时才重新取数。
   *
   * 为什么不每次切页签都重取：短视频流是随机的，来回切页签会导致"刚看的那条不见了"；
   * 只有用户改了媒体库选择（或本来就没内容）才需要换一批。
   */
  onRefreshTick(): void {
    const ids: string[] = ShortVideoPrefs.loadLibraryIds();
    if (!this.sameLibrarySelection(ids)) {
      this.loadFeed();
      return;
    }
    if (this.status === UiState.EMPTY || this.status === UiState.ERROR ||
      this.items.length === 0) {
      this.loadFeed();
    }
  }

  private sameLibrarySelection(ids: string[]): boolean {
    if (ids.length !== this.loadedLibraryIds.length) {
      return false;
    }
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== this.loadedLibraryIds[i]) {
        return false;
      }
    }
    return true;
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  /**
   * 拉取一批短视频条目。
   *
   * 取数策略：**每个已选媒体库各取一批、再合并**，而不是"一次请求多个库"——
   * Jellyfin 的 `/Items` 只接受单个 `ParentId`（多选父级要拼 `Ids` 且语义不同），
   * 逐库取也便于把某个库的失败隔离开（一个库挂了不影响其它库出内容）。
   * `SortBy=Random` 由服务端随机排序，天然满足"每次刷新不重样"。
   */
  private async loadFeed(): Promise<void> {
    const libraryIds: string[] = ShortVideoPrefs.loadLibraryIds();
    if (libraryIds.length === 0) {
      this.status = UiState.EMPTY;
      this.items = [];
      this.currentIndex = 0;
      return;
    }
    this.loadedLibraryIds = libraryIds;
    this.status = this.items.length > 0 ? UiState.REFRESHING : UiState.LOADING;
    this.refreshing = true;
    this.errorMsg = '';
    this.libraryNames = await this.resolveLibraryNames(libraryIds);

    const collected: MediaItem[] = [];
    let firstError: string = '';
    for (let i = 0; i < libraryIds.length; i++) {
      const batch: MediaItem[] = await this.fetchLibraryBatch(libraryIds[i], firstError);
      if (batch.length === 0 && firstError.length === 0) {
        continue;
      }
      for (let j = 0; j < batch.length; j++) {
        collected.push(batch[j]);
      }
    }
    this.refreshing = false;
    if (collected.length === 0) {
      // 全空有两种可能：所选库里确实没有视频，或请求失败。失败要如实报错（可重试），
      // 空则给"这批库里没有内容"的引导 —— 两者的下一步动作完全不同。
      if (firstError.length > 0) {
        this.status = UiState.ERROR;
        this.errorMsg = firstError;
      } else {
        this.status = UiState.EMPTY;
      }
      this.items = [];
      this.currentIndex = 0;
      return;
    }
    // 逐库内已是随机序；这里再整体洗一次，避免"总是先放第一个库的内容"
    this.items = this.shuffle(collected);
    this.currentIndex = 0;
    this.reachedEnd = false;
    this.status = UiState.SUCCESS;
    // 内容就绪即自动开播第一条（"打开就刷"，不需要用户再点一次）
    this.playCurrent();
  }

  /** 单个媒体库取一批条目；失败时把首个错误写进 outError 并返回空数组（不让整页失败） */
  private async fetchLibraryBatch(libraryId: string, outError: string): Promise<MediaItem[]> {
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.parentId = libraryId;
    query.startIndex = 0;
    query.limit = kShortVideoBatchSize;
    // 短视频模式只关心"能直接播的视频类条目"：电影 / 单集 / 视频 / 音乐视频
    query.includeItemTypes = 'Movie,Episode,Video,MusicVideo';
    query.sortBy = 'Random';
    query.recursive = true;
    query.fields = 'Overview,PrimaryImageAspectRatio,RunTimeTicks,ProductionYear';
    query.enableUserData = true;
    const raw: string = await JellyfinNative.queryItems(query.toJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      if (outError.length === 0) {
        outError = result.message.length > 0 ? result.message : '取短视频内容失败';
      }
      return [];
    }
    return MediaItem.fromArray(JsonUtil.extractItems(result.data));
  }

  /** 已选媒体库的名称（取服务器视图列表；取不到就退化为空，不影响出内容） */
  private async resolveLibraryNames(libraryIds: string[]): Promise<string[]> {
    const names: string[] = [];
    try {
      const raw: string = await JellyfinNative.getHomeSection('views', 60);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return names;
      }
      // 同 ShortVideoSettingsPage：`views` 段返回的就是 `/Views` 原始响应（顶层 `Items`）
      const views: Object[] = JsonUtil.extractItems(result.data as ESObject);
      for (let i = 0; i < libraryIds.length; i++) {
        for (let j = 0; j < views.length; j++) {
          const view: ESObject = views[j] as ESObject;
          if (JsonUtil.getString(view, 'Id', '') === libraryIds[i]) {
            names.push(JsonUtil.getString(view, 'Name', '媒体库'));
            break;
          }
        }
      }
    } catch (err) {
      return [];
    }
    return names;
  }

  /** Fisher–Yates 洗牌：让"每次进来/换一批"的顺序都不同（随机感的来源） */
  private shuffle(list: MediaItem[]): MediaItem[] {
    const out: MediaItem[] = list.slice();
    for (let i = out.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: MediaItem = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  // ─────────────────────────── 播放实现 ───────────────────────────

  /**
   * 播当前这一条：取播放地址 → 建 AVPlayer → 绑 surface → prepare → play。
   *
   * 每一步都可能失败（取流、建播放器、编码不支持…），失败统一走 `onItemFailed`：
   * **提示 + 给软解入口 + 自动跳过**，不让"刷"停下来。
   */
  private async playCurrent(): Promise<void> {
    const item: MediaItem | null = this.currentItem();
    this.cancelAutoSkip();
    this.stopProgressTicker();
    this.releasePlayer();
    this.playbackError = '';
    this.videoReady = false;
    this.paused = false;
    this.positionMs = 0;
    this.durationMs = 0;
    if (item === null) {
      return;
    }
    const raw: string = await JellyfinNative.playerOpen(item.id, '{}');
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.onItemFailed(result.message.length > 0 ? `获取播放地址失败：${result.message}` : '获取播放地址失败');
      return;
    }
    const playUrl: string = JsonUtil.getString(result.data as ESObject, 'playUrl', '');
    if (playUrl.length === 0) {
      this.onItemFailed('服务器没有给出播放地址');
      return;
    }
    try {
      this.avPlayer = await media.createAVPlayer();
    } catch (err) {
      this.onItemFailed('创建播放器失败');
      return;
    }
    this.playingItemId = item.id;
    this.attachPlayerHandlers(this.avPlayer);
    try {
      this.avPlayer.url = playUrl;
    } catch (err) {
      this.onItemFailed('设置播放地址失败');
    }
  }

  private attachPlayerHandlers(player: media.AVPlayer): void {
    player.on('stateChange', (state: string) => {
      // 切到下一条后旧播放器的事件必须忽略（否则会污染新条目的状态）
      if (this.avPlayer !== player) {
        return;
      }
      if (state === 'initialized') {
        this.bindSurface();
        if (this.surfaceId.length > 0) {
          player.prepare();
        }
        // surface 尚未就绪时由 XComponent.onLoad 补一次 prepare
      } else if (state === 'prepared') {
        if (player.duration > 0) {
          this.durationMs = player.duration;
        }
        try {
          // 短视频要"铺满屏幕"：等比放大 + 裁剪（与设置里"填充"同一套语义）
          player.videoScaleType = kScaleTypeFitCrop;
        } catch (err) {
          // 部分设备不支持该属性：退回默认拉伸即可，不影响播放
        }
        player.play();
      } else if (state === 'playing') {
        this.videoReady = true;
        this.paused = false;
        this.startProgressTicker();
        this.reportProgress(false);
      } else if (state === 'paused') {
        this.paused = true;
        this.reportProgress(true);
      } else if (state === 'completed') {
        // 播完自动下一条 —— 这是"连续刷"的关键
        this.advance(1);
      } else if (state === 'error') {
        // 实测顺序：`stateChange='error'` 常常先于 `error` 事件到达，此时还拿不到错误码。
        // 文案因此给"人话 + 下一步"，而不是一个光秃秃的"播放出错"。
        this.onItemFailed('本机无法播放该内容（可能是硬解不支持）');
      }
    });
    player.on('error', (err: BusinessError) => {
      if (this.avPlayer !== player) {
        return;
      }
      // 5400106 = 编码不支持（如模拟器上的 HEVC）；801 = 能力不支持。
      // 这类内容并非不可看 —— 播放页有 FFmpeg 软解回退，因此提示里给出入口。
      const hint: string = (err.code === 5400106 || err.code === 801)
        ? '本机硬解不支持该编码' : `播放器错误(code=${err.code})`;
      this.onItemFailed(hint);
    });
  }

  /** surface 就绪/状态变化时把 surfaceId 交给播放器（AVPlayer 要求 initialized 及之后才能设） */
  private bindSurface(): void {
    if (this.avPlayer === null || this.surfaceId.length === 0) {
      return;
    }
    const state: string = this.avPlayer.state;
    if (state === 'initialized' || state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed') {
      try {
        this.avPlayer.surfaceId = this.surfaceId;
      } catch (err) {
        // 状态恰好又变了：下一次事件里会再绑
      }
    }
  }

  /** 单击画面：暂停/继续 */
  private togglePause(): void {
    if (this.avPlayer === null || this.playbackError.length > 0) {
      return;
    }
    if (this.paused) {
      this.avPlayer.play();
    } else {
      this.avPlayer.pause();
    }
  }

  private pausePlayback(): void {
    if (this.avPlayer !== null && !this.paused) {
      try {
        this.avPlayer.pause();
      } catch (err) {
        // 已处于不可暂停的状态：忽略
      }
    }
    this.stopProgressTicker();
  }

  /** 上/下一条（delta = ±1）；越界即"到底了" */
  private advance(delta: number): void {
    const next: number = this.currentIndex + delta;
    if (next < 0 || next >= this.items.length) {
      this.stopProgressTicker();
      this.releasePlayer();
      this.reachedEnd = delta > 0;
      return;
    }
    this.reachedEnd = false;
    this.currentIndex = next;
    this.playCurrent();
  }

  /** 条目播放失败：提示 + 自动跳过（见 kAutoSkipMs） */
  private onItemFailed(message: string): void {
    this.playbackError = message;
    this.stopProgressTicker();
    this.releasePlayer();
    this.cancelAutoSkip();
    this.skipTimerId = setTimeout(() => {
      this.skipTimerId = -1;
      this.advance(1);
    }, kAutoSkipMs);
  }

  private cancelAutoSkip(): void {
    if (this.skipTimerId >= 0) {
      clearTimeout(this.skipTimerId);
      this.skipTimerId = -1;
    }
  }

  /** 失败浮层的「软解播放」：转到播放页（那里有 FFmpeg 软解回退） */
  private openInPlayer(item: MediaItem): void {
    this.cancelAutoSkip();
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: {
        itemId: item.id,
        title: item.displayTitle(),
        startPositionMs: Math.floor(item.playbackPositionTicks / 10000)
      }
    });
  }

  /** 进度：1 秒刷新界面读数，5 秒节流上报服务端（与播放页同一套节流口径） */
  private startProgressTicker(): void {
    this.stopProgressTicker();
    this.progressTimerId = setInterval(() => {
      if (this.avPlayer !== null) {
        this.positionMs = this.avPlayer.currentTime;
        if (this.avPlayer.duration > 0) {
          this.durationMs = this.avPlayer.duration;
        }
      }
      this.reportProgress(false);
    }, 1000);
  }

  private stopProgressTicker(): void {
    if (this.progressTimerId >= 0) {
      clearInterval(this.progressTimerId);
      this.progressTimerId = -1;
    }
  }

  private reportProgress(isPaused: boolean): void {
    if (this.playingItemId.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (!isPaused && this.lastReportAt > 0 && now - this.lastReportAt < kReportIntervalMs) {
      return;
    }
    this.lastReportAt = now;
    const ticks: number = Math.floor(this.positionMs * 10000);
    PlaybackState.set(this.playingItemId, ticks);
    JellyfinNative.reportPlaybackProgress(this.playingItemId, ticks, isPaused);
  }

  /** 释放播放器并补发 stopped（切条/离页都必须走这里，避免服务端会话堆积） */
  private releasePlayer(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    this.videoReady = false;
    if (player !== null) {
      try {
        player.off('stateChange');
        player.off('error');
      } catch (err) {
        // 监听器可能已随 release 清理
      }
      try {
        player.release();
      } catch (err) {
        // 已在错误态：忽略
      }
    }
    if (this.playingItemId.length > 0) {
      const ticks: number = Math.floor(this.positionMs * 10000);
      PlaybackState.set(this.playingItemId, ticks);
      JellyfinNative.reportPlaybackStopped(this.playingItemId, ticks);
      this.playingItemId = '';
    }
    this.lastReportAt = 0;
  }

  /** 进度百分比（0..1）；时长未知时为 0 */
  private progressRatio(): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    const r: number = this.positionMs / this.durationMs;
    return Math.min(1, Math.max(0, r));
  }

  /** 当前条目是否正在页内播放（决定封面是否让位给视频） */
  private isVideoPlaying(index: number): boolean {
    return index === this.currentIndex && this.videoReady && this.playbackError.length === 0;
  }

  /** 兼容旧入口：FeedCard 的按钮仍复用播放页导航（详情/软解都走它） */
  private playItem(item: MediaItem): void {
    this.openInPlayer(item);
  }

  private openSettings(): void {
    router.pushUrl({ url: 'pages/settings/ShortVideoSettingsPage' });
  }

  private currentItem(): MediaItem | null {
    if (this.currentIndex < 0 || this.currentIndex >= this.items.length) {
      return null;
    }
    return this.items[this.currentIndex];
  }

  /** 顶部一行：内容来源 + 换一批 + 设置入口（贴在顶栏下方，随页面滚动无关） */
  @Builder
  FeedToolbar() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('短视频')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
        Text(this.libraryNames.length > 0
          ? `来自：${this.libraryNames.join(' / ')}`
          : '来自已选的短视频媒体库')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('换一批', { type: ButtonType.Normal, stateEffect: false })
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textPrimary)
        .backgroundColor(this.colors().surfacePressed)
        .borderRadius(ThemeConstants.BADGE_RADIUS)
        .height(32)
        .padding({ left: 12, right: 12 })
        .enabled(!this.refreshing)
        .onClick(() => { this.loadFeed(); })

      Button('设置', { type: ButtonType.Normal, stateEffect: false })
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textPrimary)
        .backgroundColor(this.colors().surfacePressed)
        .borderRadius(ThemeConstants.BADGE_RADIUS)
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => { this.openSettings(); })
    }
    .width('100%')
    .padding({
      left: ThemeConstants.PAGE_PADDING,
      right: ThemeConstants.PAGE_PADDING,
      top: 8 + this.topInsetVp,
      bottom: 8
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 一屏一条短视频：封面铺满 + 底部渐变 + 标题/简介 + 播放按钮与页码 */
  @Builder
  FeedCard(item: MediaItem, index: number) {
    Stack({ alignContent: Alignment.Bottom }) {
      // 封面：优先横图（Backdrop）/ 退化为竖图（Primary）。
      // **正在页内播放的那一条不画封面** —— 视频层在本页最底下，封面会把它整块挡住；
      // 封面只作为"还没起播 / 播不了"时的占位。
      if (!this.isVideoPlaying(index)) {
        JellyfinImage({
          url: item.imageUrl(900, item.backdropTag.length > 0 ? 'Backdrop' : 'Primary'),
          imgWidth: 900,
          imgHeight: 1600,
          cornerRadius: 0,
          objectFit: ImageFit.Cover,
          placeholderIcon: 'movie'
        })
          .width('100%')
          .height('100%')
      }

      // 底部渐变：保证文字在任何封面上都可读（与播放页同一套 scrim 令牌）
      Column()
        .width('100%')
        .height('46%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], [this.colors().scrimHeavy, 1.0]]
        })

      Column({ space: 10 }) {
        Text(item.displayTitle())
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().onOverlay)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.metaLine())
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onOverlayMuted)
          .maxLines(1)
          .width('100%')
        if (item.overview.length > 0) {
          Text(item.overview)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().onOverlayMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Row({ space: 12 }) {
          // 页内已自动播放：不再放「播放」（点画面即可暂停/继续，避免与单击语义打架），
          // 主按钮改为「详情」，次按钮是「重播」（从头再放这一条）。
          Button('详情', { type: ButtonType.Normal, stateEffect: false })
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brandPrimary)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .padding({ left: 28, right: 28 })
            .onClick(() => {
              router.pushUrl({
                url: 'pages/DetailPage',
                params: { itemId: item.id, title: item.displayTitle() }
              });
            })

          Button('重播', { type: ButtonType.Normal, stateEffect: false })
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onOverlay)
            .backgroundColor(this.colors().overlayControl)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .padding({ left: 22, right: 22 })
            .onClick(() => {
              this.currentIndex = index;
              this.playCurrent();
            })

          Blank()

          Text(`${index + 1}/${this.items.length}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().onOverlayMuted)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    // 单击 = 暂停/继续。
    //
    // 为什么挂在**页面根节点**而不是"覆盖在 Swiper 之上的整屏透明层"：
    // 设备实测（模拟器）覆盖层方案只在第一次点击生效，暂停之后点击再也不到回调
    // （同一 Stack 里条件分支一增删，覆盖层的命中测试就不稳定了）；
    // 挂在页面根节点上则与页面同生命周期，且**仍在 Swiper 内部** ——
    // 纵向滑动仍由 Swiper 接管，不会出现"点得着但滑不动"。
    .onClick(() => {
      if (index === this.currentIndex) {
        this.togglePause();
      }
    })
  }

  build() {
    Column() {
      this.FeedToolbar()

      if (this.status === UiState.INITIAL || this.status === UiState.LOADING) {
        LoadingState({ hint: '正在准备短视频…' })
      } else if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
          detail: '请检查网络或服务器状态',
          actionLabel: '重试',
          onAction: () => { this.loadFeed(); }
        })
      } else if (this.status === UiState.EMPTY) {
        // 空态分两种：没配过库 → 引导去设置；配过但没内容 → 如实说明
        EmptyState({
          message: ShortVideoPrefs.loadLibraryIds().length === 0
            ? '还没有设置短视频媒体库'
            : '所选的媒体库里没有可播放的视频',
          detail: ShortVideoPrefs.loadLibraryIds().length === 0
            ? '在设置里勾选要进入短视频模式的媒体库，「视频」页会随机连播这些库里的内容'
            : '可以换几个媒体库，或先往库里添加内容',
          actionLabel: '去设置',
          icon: $r('sys.symbol.play_circle'),
          onAction: () => { this.openSettings(); }
        })
      } else {
        // 视频层（最底）→ 播放流（封面/文案/按钮）→ 失败浮层 → 到底提示
        Stack({ alignContent: Alignment.Center }) {
          // AVPlayer 的渲染目标。**不要** `libraryname`：
          // 软解用的原生 XComponent 桥是全进程单例，本页只走硬解（解不了的内容引导去播放页），
          // 挂上同一个 libraryname 会与播放页争抢那块桥状态。
          XComponent({
            id: 'short_video_surface',
            type: XComponentType.SURFACE,
            controller: this.surfaceController
          })
            .width('100%')
            .height('100%')
            .onLoad(() => {
              this.surfaceId = this.surfaceController.getXComponentSurfaceId();
              this.bindSurface();
              // surface 比 url 晚到：此刻播放器多半已 initialized，补一次 prepare
              if (this.avPlayer !== null && this.avPlayer.state === 'initialized') {
                this.avPlayer.prepare();
              }
            })

          Swiper() {
            ForEach(this.items, (item: MediaItem, index: number) => {
              this.FeedCard(item, index)
            }, (item: MediaItem) => item.id)
          }
          .vertical(true)
          .loop(false)
          .indicator(false)
          .index(this.currentIndex)
          .onChange((index: number) => {
            if (index === this.currentIndex) {
              return;
            }
            // 滑到哪条就播哪条（这就是"连续刷"）
            this.currentIndex = index;
            this.playCurrent();
          })
          .width('100%')
          .height('100%')

          // 暂停时的中央提示
          if (this.paused && this.playbackError.length === 0) {
            Column() {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(ThemeConstants.ICON_HERO)
                .fontColor([this.colors().onOverlay])
            }
            .width(84)
            .height(84)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(this.colors().overlayControlStrong)
            .borderRadius(42)
            .hitTestBehavior(HitTestMode.None)
          }

          // 本条播放失败：如实说明 + 软解入口 + 自动跳过倒计时
          if (this.playbackError.length > 0) {
            Column({ space: 12 }) {
              Text(this.playbackError)
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontColor(this.colors().onOverlay)
              Text(`将在 ${Math.round(kAutoSkipMs / 1000)} 秒后自动跳过`)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().onOverlayMuted)
              Row({ space: 12 }) {
                Button('用软解播放', { type: ButtonType.Normal, stateEffect: false })
                  .fontSize(ThemeConstants.META_MEDIUM)
                  .fontColor(this.colors().onBrand)
                  .backgroundColor(this.colors().brandPrimary)
                  .borderRadius(ThemeConstants.BUTTON_RADIUS)
                  .height(ThemeConstants.BUTTON_HEIGHT)
                  .onClick(() => {
                    const item: MediaItem | null = this.currentItem();
                    if (item !== null) {
                      this.openInPlayer(item);
                    }
                  })
                Button('跳过', { type: ButtonType.Normal, stateEffect: false })
                  .fontSize(ThemeConstants.META_MEDIUM)
                  .fontColor(this.colors().onOverlay)
                  .backgroundColor(this.colors().overlayControl)
                  .borderRadius(ThemeConstants.BUTTON_RADIUS)
                  .height(ThemeConstants.BUTTON_HEIGHT)
                  .onClick(() => {
                    this.cancelAutoSkip();
                    this.advance(1);
                  })
              }
            }
            .padding({ left: 24, right: 24, top: 20, bottom: 20 })
            .backgroundColor(this.colors().overlayControlStrong)
            .borderRadius(ThemeConstants.CARD_RADIUS)
          }

          // 进度条：短视频也要能看到"还剩多少"（细线，压在底部）
          if (this.videoReady) {
            Column() {
              Progress({ value: this.progressRatio() * 100, total: 100,
                type: ProgressType.Linear })
                .color(this.colors().brandPrimary)
                .backgroundColor('#33000000')
                .width('100%')
                .height(3)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .hitTestBehavior(HitTestMode.None)
          }

          // 到底了：不自动循环（避免"永远刷不完"的假象），给「换一批」
          if (this.reachedEnd) {
            Column({ space: 14 }) {
              Text('这批已经看完了')
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontColor(this.colors().onOverlay)
              Button('换一批', { type: ButtonType.Normal, stateEffect: false })
                .fontSize(ThemeConstants.META_MEDIUM)
                .fontColor(this.colors().onBrand)
                .backgroundColor(this.colors().brandPrimary)
                .borderRadius(ThemeConstants.BUTTON_RADIUS)
                .height(ThemeConstants.BUTTON_HEIGHT)
                .onClick(() => { this.loadFeed(); })
            }
            .padding({ left: 24, right: 24, top: 20, bottom: 20 })
            .backgroundColor(this.colors().overlayControlStrong)
            .borderRadius(ThemeConstants.CARD_RADIUS)
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
