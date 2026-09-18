import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { MediaItem } from '../models/MediaItem';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { ShortVideoPrefs, kShortVideoBatchSize } from '../common/ShortVideoPrefs';
import { JellyfinImage } from '../components/JellyfinImage';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';

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

  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private currentIndex: number = 0;
  /** 已选媒体库的名称（用于顶部说明"内容来自哪儿"；id 才是配置，名称只用于展示） */
  @State private libraryNames: string[] = [];
  @State private refreshing: boolean = false;
  /** 本次取数所用的媒体库选择（用于判断"切回本页时配置是否变了"） */
  private loadedLibraryIds: string[] = [];

  aboutToAppear(): void {
    this.loadFeed();
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
    this.status = UiState.SUCCESS;
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

  /** 播放当前这一条：复用播放页（硬解优先、失败自动回退软解） */
  private playItem(item: MediaItem): void {
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
      top: 8,
      bottom: 8
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 一屏一条短视频：封面铺满 + 底部渐变 + 标题/简介 + 播放按钮与页码 */
  @Builder
  FeedCard(item: MediaItem, index: number) {
    Stack({ alignContent: Alignment.Bottom }) {
      // 封面：优先横图（Backdrop）/ 退化为竖图（Primary）；短视频模式下画面要"铺满一屏"
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
          Button('播放', { type: ButtonType.Normal, stateEffect: false })
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brandPrimary)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .padding({ left: 28, right: 28 })
            .onClick(() => { this.playItem(item); })

          Button('详情', { type: ButtonType.Normal, stateEffect: false })
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onOverlay)
            .backgroundColor(this.colors().overlayControl)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .padding({ left: 22, right: 22 })
            .onClick(() => {
              router.pushUrl({
                url: 'pages/DetailPage',
                params: { itemId: item.id, title: item.displayTitle() }
              });
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
          this.currentIndex = index;
        })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
