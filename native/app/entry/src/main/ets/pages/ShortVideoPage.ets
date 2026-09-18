import router from '@ohos.router';
import media from '@ohos.multimedia.media';
import display from '@ohos.display';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PlaybackState } from '../common/PlaybackState';
import { PlayerAspect, kScaleTypeFit, kScaleTypeFitCrop } from '../common/PlayerAspect';
import { WindowFullscreen, PlayerOrientation } from '../common/WindowFullscreen';
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

/** 页内软解的拉帧下限间隔（与播放页同一套自调度思路：上一帧完成即排下一帧） */
const kSoftPullMinGapMs: number = 8;

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

  // ─────────────────────── 横屏观看 ───────────────────────
  //
  // 短视频内容横竖皆有；横屏时同一个"适应"盒子计算会给出**更大的画面**
  // （可用区域从 20:9 的窄长变成宽屏），因此除了跟随传感器，还要给一个显式锁定入口
  // （躺卧观看时传感器会被机身姿态反复打断）。窗口实例与方向都复用播放页那套
  // `WindowFullscreen`，不另起一套平台调用。
  /** 窗口实例（方向控制需要） */
  private windowRef: window.Window | null = null;
  /** 方向选择：跟随系统 / 横屏 / 竖屏 */
  @State private orientation: PlayerOrientation = 'auto';

  // ───────────────── 页内软解回退（硬解不支持时不再跳过）─────────────────
  //
  // 为什么能在本页做软解：软解需要一块 EGL 可渲染的显示面，本页的 XComponent 就有
  // （`surfaceId` 路径由原生侧自行创建 window）。**不需要**播放页那块
  // `OH_NativeXComponent` 桥 —— 那是全进程单例，两页同时用会互相抢状态。
  // 渲染器单例按"surfaceId 是否一致"校验复用（见 boundToSurfaceId），因此
  // 播放页与本页可以轮流接管同一个渲染器。
  /** 当前条目是否正走页内软解 */
  @State private softActive: boolean = false;
  private softPulling: boolean = false;
  private softPullTimerId: number = -1;
  /** XComponent 的像素尺寸（软解渲染缓冲几何按它协商） */
  private surfaceW: number = 0;
  private surfaceH: number = 0;

  // ───────────────── 画面比例（竖屏比例不对的修复）─────────────────
  //
  // 此前的做法是"XComponent 铺满整屏 + `videoScaleType = FIT_CROP`"：
  // 竖屏是 20:9 的窄长屏，而内容多为 16:9 / 2.35:1 的横片 —— 等比铺满意味着**横向被裁掉大半**
  // （观感就是"比例不对/画面被切"）；而一旦设备不支持该属性（setter 抛错被兜住），
  // AVPlayer 默认的 `VIDEO_SCALE_TYPE_FIT` 是**拉伸铺满**，直接变形。
  // 现在改成播放页那套已经验证过的做法：**把视频面的宽高比算成与画面一致**，
  // 再把 scaleType 设为 FIT —— 同比例的 FIT 没有可拉伸/可裁剪的余地，比例必然正确。
  /** 画面原始像素尺寸（硬解来自 AVPlayer.width/height，软解来自 softPlayOpen 返回值） */
  @State private videoW: number = 0;
  @State private videoH: number = 0;
  /** 可用区域（vp，来自根容器实测）：横竖屏切换后会变，画面盒子随之重算 */
  @State private areaW: number = 0;
  @State private areaH: number = 0;
  /** 当前是否横屏（宽 > 高）：控件布局与画面盒子都按它走 */
  @State private landscape: boolean = false;
  /** 页内软解的解码目标宽度（对齐协商出的渲染缓冲） */
  private softDecodeMaxWidth: number = 0;
  private skipTimerId: number = -1;
  private lastReportAt: number = 0;

  aboutToAppear(): void {
    this.loadFeed();
  }

  aboutToDisappear(): void {
    this.stopProgressTicker();
    this.cancelAutoSkip();
    this.stopSoftPlayback();
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
      if (this.softActive) {
        // 软解：切走即停帧循环（回来自会自动续上，见下面 else 分支）
        this.stopSoftPullLoop();
        return;
      }
      // 只对"因切页签而暂停"做标记：用户自己按暂停的，切回来不该被自动续播
      if (this.avPlayer !== null && !this.paused) {
        this.pausePlayback();
        this.pausedByTabSwitch = true;
      }
      return;
    }
    // 切回本页：软解重启帧循环；硬解用 `play()` 续播（**不是** `playCurrent()`，后者会从头重开）
    if (this.softActive) {
      if (!this.paused) {
        this.startSoftPullLoop();
        this.startProgressTicker();
      }
      return;
    }
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
    // 切条/重开前先把页内软解收掉：硬解与软解不能同时占同一块 surface
    this.stopSoftPlayback();
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
        // 画面真实尺寸：视频面按它重算宽高比（这是比例正确的前提）
        if (player.width > 0 && player.height > 0) {
          this.videoW = player.width;
          this.videoH = player.height;
        }
        try {
          // 视频面已按画面比例设过尺寸 ⇒ 同比例的 FIT 不会拉伸；
          // 若拿不到画面尺寸（videoW/H 仍为 0，面暂时铺满），FIT_CROP 至少保证不出现黑边。
          player.videoScaleType = (this.videoW > 0 && this.videoH > 0)
            ? kScaleTypeFit : kScaleTypeFitCrop;
        } catch (err) {
          // 部分设备不支持该属性：此时靠"视频面与画面同比例"兜底，比例仍然正确
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
    if (this.softActive) {
      // 软解没有暂停 API：暂停 = 停掉帧循环（画面停在最后一帧），恢复 = 重启帧循环
      if (this.paused) {
        this.paused = false;
        this.startSoftPullLoop();
        this.startProgressTicker();
      } else {
        this.paused = true;
        this.stopSoftPullLoop();
        this.stopProgressTicker();
      }
      this.reportProgress(this.paused);
      return;
    }
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
    // ── 就地软解续播（本页自己的 surface）────────────────────────────────
    // 硬解解不了的内容（模拟器上的 HEVC 是常态）不再"提示 + 跳过"，
    // 而是当场用 FFmpeg 软解接着播 —— 这才是短视频该有的连续感。
    if (!this.softActive && this.surfaceId.length > 0) {
      this.startSoftPlayback();
      return;
    }
    // 软解也不行（如本构建未链接 FFmpeg）：退回"提示 + 自动跳过"，不把用户卡住
    this.skipTimerId = setTimeout(() => {
      this.skipTimerId = -1;
      this.advance(1);
    }, kAutoSkipMs);
  }

  /** 就地软解：打开会话 → 按当前位置起播 → 自调度拉帧 */
  private async startSoftPlayback(): Promise<void> {
    const item: MediaItem | null = this.currentItem();
    if (item === null) {
      return;
    }
    this.softActive = true;
    this.playbackError = '';   // 软解接管后不再显示"本机无法播放"
    this.cancelAutoSkip();
    const seekSec: number = this.positionMs / 1000;
    // softPlayOpen 是**异步**接口（内部要取 PlaybackInfo + 探测容器），必须 await
    const raw: string = await JellyfinNative.softPlayOpen(item.id, this.surfaceId, this.surfaceW,
                                                         this.surfaceH, 'surface', '{}');
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null ||
        !JsonUtil.getBoolean(result.data as ESObject, 'ok', false)) {
      const why: string = result.data !== null
        ? JsonUtil.getString(result.data as ESObject, 'error', '软解打开失败') : '软解打开失败';
      this.softActive = false;
      this.playbackError = `本机无法播放该内容（${why}）`;
      this.skipTimerId = setTimeout(() => {
        this.skipTimerId = -1;
        this.advance(1);
      }, kAutoSkipMs);
      return;
    }
    // ── EGL 渲染器必须在**本线程（UI 线程）**初始化 ────────────────────────
    // `softPlayOpen` 跑在原生工作线程上，**故意不做** EGL 初始化：
    // EGL/DGLES 的"当前上下文"是线程私有状态，在工作线程初始化、在 UI 线程逐帧
    // `eglSwapBuffers` 会每帧失败（`EGL_BAD_SURFACE`，画面全黑且无报错）——
    // 那正是此前"软解黑屏"的根因。因此这里用同步接口在当前线程建好渲染器，
    // 并走 `surfaceId` 路径（本页自己的 XComponent），不碰播放页那块原生桥单例。
    // 渲染缓冲几何必须**按视频尺寸**协商，不能直接用整屏尺寸：
    // 「视频」页的 XComponent 是满屏（实测 1260×2294），而模拟器的软件 GL 交换不了这么大的缓冲
    // （实测 `eglSwapBuffers 0x12301`，且降级阶梯折半后依旧失败 —— 表面创建后
    // `SET_BUFFER_GEOMETRY` 已不生效）。播放页之所以没这个问题，是因为它的 XComponent 本身
    // 就按画面比例设了尺寸（1259×537）。这里按"视频尺寸等比缩放到组件内"取几何，
    // 顺带把解码目标宽度对齐到该几何 —— 既省 swscale 又不浪费解码算力。
    const videoW: number = JsonUtil.getNumber(result.data as ESObject, 'width', 0);
    const videoH: number = JsonUtil.getNumber(result.data as ESObject, 'height', 0);
    if (videoW > 0 && videoH > 0) {
      // 软解路径同样要让视频面与画面同比例（否则 2.35:1 的片子会被拉进 16:9 的盒子）
      this.videoW = videoW;
      this.videoH = videoH;
    }
    let renderW: number = this.surfaceW;
    let renderH: number = this.surfaceH;
    if (videoW > 0 && videoH > 0 && this.surfaceW > 0 && this.surfaceH > 0) {
      const k: number = Math.min(this.surfaceW / videoW, this.surfaceH / videoH);
      renderW = Math.max(2, Math.floor(videoW * k));
      renderH = Math.max(2, Math.floor(videoH * k));
    }
    const initRaw: string = JellyfinNative.softPlayInitRenderer(this.surfaceId, renderW,
                                                               renderH, 'surface');
    const initResult: NativeResult = JellyfinNative.parseResult(initRaw);
    const renderReady: boolean = initResult.ok && initResult.data !== null
      && JsonUtil.getBoolean(initResult.data as ESObject, 'renderReady', false);
    if (!renderReady) {
      const renderErr: string = initResult.ok && initResult.data !== null
        ? JsonUtil.getString(initResult.data as ESObject, 'renderError', '') : initResult.message;
      this.softActive = false;
      this.playbackError = `软解画面无法上屏${renderErr.length > 0 ? '：' + renderErr : ''}`;
      JellyfinNative.softPlayClose();
      this.skipTimerId = setTimeout(() => {
        this.skipTimerId = -1;
        this.advance(1);
      }, kAutoSkipMs);
      return;
    }
    this.playingItemId = item.id;
    // 解码宽度对齐渲染缓冲（0 = 按源分辨率，会白白多解一倍像素）
    const negotiated: number = initResult.data !== null
      ? JsonUtil.getNumber(initResult.data as ESObject, 'renderWidth', 0) : 0;
    this.softDecodeMaxWidth = negotiated > 0 ? negotiated : renderW;
    if (seekSec > 1) {
      JellyfinNative.softPlaySeek(seekSec);
    }
    this.videoReady = true;
    this.paused = false;
    this.startSoftPullLoop();
    this.startProgressTicker();
  }

  /** 页内软解的帧循环：自调度（上一帧完成即排下一帧），与播放页同一套思路 */
  private startSoftPullLoop(): void {
    this.stopSoftPullLoop();
    this.scheduleSoftPull(0);
  }

  private scheduleSoftPull(delayMs: number): void {
    if (this.softPullTimerId !== -1) {
      clearTimeout(this.softPullTimerId);
      this.softPullTimerId = -1;
    }
    this.softPullTimerId = setTimeout(() => {
      this.softPullTimerId = -1;
      this.pullSoftFrame();
    }, delayMs);
  }

  private stopSoftPullLoop(): void {
    if (this.softPullTimerId !== -1) {
      clearTimeout(this.softPullTimerId);
      this.softPullTimerId = -1;
    }
  }

  private async pullSoftFrame(): Promise<void> {
    if (!this.softActive || this.softPulling) {
      return;
    }
    // 切走页签/离开本页就停：软解也在放声音（无音频输出，但别白烧 CPU）
    if (this.activeTab !== kVideoTabIndex) {
      return;
    }
    this.softPulling = true;
    try {
      const raw: string = await JellyfinNative.softPlayNextFrame(this.softDecodeMaxWidth);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (result.ok && result.data !== null) {
        const frame: ESObject = result.data as ESObject;
        if (JsonUtil.getBoolean(frame, 'ok', false)) {
          // 渲染必须在 UI 线程（本函数运行在 ArkTS 侧 = UI 线程）
          JellyfinNative.softPlayRenderLast();
          const pts: number = JsonUtil.getNumber(frame, 'ptsSec', 0);
          if (pts > 0) {
            this.positionMs = Math.floor(pts * 1000);
          }
          if (this.playingItemId.length > 0) {
            this.reportProgress(false);
          }
        } else {
          const reason: string = JsonUtil.getString(frame, 'error', '');
          if (reason === 'eof') {
            this.advance(1);
            return;
          }
        }
      }
    } catch (err) {
      // 单帧失败不致命：下一次调度会重试
    } finally {
      this.softPulling = false;
      if (this.softActive && !this.paused && this.activeTab === kVideoTabIndex) {
        this.scheduleSoftPull(kSoftPullMinGapMs);
      }
    }
  }

  /** 关掉页内软解（切条/离页/改走硬解时都要调） */
  private stopSoftPlayback(): void {
    this.stopSoftPullLoop();
    if (this.softActive) {
      this.softActive = false;
      JellyfinNative.softPlayClose();
    }
  }

  private cancelAutoSkip(): void {
    if (this.skipTimerId >= 0) {
      clearTimeout(this.skipTimerId);
      this.skipTimerId = -1;
    }
  }

  /**
   * 方向按钮的文案：跟随系统 / 横屏 / 竖屏。
   *
   * 为什么短视频也要有方向控制：短视频内容横竖皆有，而**横屏时同一个"适应"盒子计算
   * 会给出更大的画面**（可用区域从 20:9 的窄长变成宽屏）；只靠传感器自动旋转，
   * 躺卧观看时会被机身姿态反复打断，所以和播放页一样给一个显式锁定入口。
   */
  private orientationLabel(): string {
    if (this.orientation === 'landscape') {
      return '横屏';
    }
    if (this.orientation === 'portrait') {
      return '竖屏';
    }
    return '跟随系统';
  }

  /** 循环切换方向（跟随系统 → 横屏 → 竖屏 → 跟随系统） */
  private cycleOrientation(): void {
    const next: PlayerOrientation = this.orientation === 'auto'
      ? 'landscape' : (this.orientation === 'landscape' ? 'portrait' : 'auto');
    this.orientation = next;
    if (this.windowRef === null) {
      window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
        this.windowRef = win;
        WindowFullscreen.setOrientation(this.windowRef, next);
      }).catch(() => {
        // 取不到窗口：方向设置失败，但短视频页仍可用（跟随系统）
      });
      return;
    }
    WindowFullscreen.setOrientation(this.windowRef, next);
  }

  /** 失败浮层的「软解播放」：转到播放页（那里有 FFmpeg 软解回退） */
  private openInPlayer(item: MediaItem): void {    this.cancelAutoSkip();
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
    // 软解正在跑时不把 videoReady 打回 false（否则封面会盖住软解画面）
    if (!this.softActive) {
      this.videoReady = false;
    }
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

  /** 屏幕像素密度（px / vp）—— 「原始」比例换算用（与播放页同一口径） */
  private density(): number {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      return d > 0 ? d : 1;
    } catch (err) {
      return 1;
    }
  }

  /**
   * 视频面（XComponent）的尺寸：**按画面比例**适配可用区域（vp）。
   *
   * 与播放页共用 `PlayerAspect.box(..., 'contain', ...)`：等比、完整可见、多余留黑边。
   * 画面尺寸未知（尚未 prepared）时铺满可用区域，拿到尺寸后本函数会被重新调用。
   * 横屏不做特殊分支 —— 可用区域横向变长，同一个"适应"计算自然给出更大的画面。
   */
  private videoBoxWidth(): Length {
    if (this.videoW <= 0 || this.videoH <= 0) {
      // 画面尺寸未知：先铺满（拿到尺寸后本函数会被重新求值）
      return this.areaW > 0 ? this.areaW : '100%';
    }
    return PlayerAspect.box('contain', this.videoW, this.videoH, this.areaW, this.areaH,
                            this.density()).width;
  }

  private videoBoxHeight(): Length {
    if (this.videoW <= 0 || this.videoH <= 0) {
      return this.areaH > 0 ? this.areaH : '100%';
    }
    return PlayerAspect.box('contain', this.videoW, this.videoH, this.areaW, this.areaH,
                            this.density()).height;
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

      // 方向：跟随系统 / 横屏 / 竖屏 —— 短视频同样需要横屏全屏观看
      // （横屏下同一个"适应"盒子计算会给出更大的画面，见 videoBoxWidth/Height）
      Button(this.orientationLabel(), { type: ButtonType.Normal, stateEffect: false })
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textPrimary)
        .backgroundColor(this.colors().surfacePressed)
        .borderRadius(ThemeConstants.BADGE_RADIUS)
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => { this.cycleOrientation(); })

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
            // 按画面比例设尺寸（Stack 居中）—— 这是"比例正确"的根本：
            // 不再让等比/裁剪逻辑去猜，而是让视频面的宽高比与画面一致。
            .width(this.videoBoxWidth())
            .height(this.videoBoxHeight())
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              // 软解渲染缓冲几何按组件像素尺寸协商（与播放页同一口径）
              const density: number = display.getDefaultDisplaySync().densityPixels;
              this.surfaceW = Math.round(Number(newArea.width) * density);
              this.surfaceH = Math.round(Number(newArea.height) * density);
            })
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
    // 可用区域实测（vp）：横竖屏切换/窗口变化后画面盒子与控件布局都要重算
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      const h: number = Number(newArea.height);
      if (w > 0 && h > 0) {
        this.areaW = w;
        this.areaH = h;
        this.landscape = w > h;
      }
    })
  }
}
