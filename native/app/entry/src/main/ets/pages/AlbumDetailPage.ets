import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { MediaItem } from '../models/MediaItem';
import { formatTicks } from '../common/format';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';

/** 一张专辑的曲目上限（超出部分极少见；大合辑走分页是后续项） */
const kTrackLimit: number = 500;

/**
 * 专辑详情页：专辑信息 + 曲目列表 + 播放全部。
 *
 * 为什么需要它：曲目（`Audio`）是音乐链路的最后一层 —— 音乐库 → 艺术家 → 专辑 → **曲目**。
 * 这一页同时承担「音乐详情」与「播放入口」两个职责：
 *   1. 展示专辑封面、名称、艺术家、年份、曲目数与总时长；
 *   2. 列出曲目（序号 / 标题 / 时长），点单曲播放；
 *   3. 「播放全部」把整张专辑按顺序交给播放器。
 *
 * 为什么单曲信息里读的是 `IndexNumber` 与 `RunTimeTicks`：
 * Jellyfin 的 `Audio` 条目用它们表示音轨号与时长（与 `Episode` 用 `IndexNumber` 一致）。
 *
 * 播放交给 `pages/MusicPlayerPage`（音频专用 UI + AVSession `audio` 类型）。
 */
@Entry
@Component
struct AlbumDetailPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private albumId: string = '';
  @State private albumName: string = '专辑';
  @State private artistName: string = '';
  @State private coverUrl: string = '';
  @State private year: number = 0;
  @State private tracks: MediaItem[] = [];
  @State private totalMs: number = 0;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['albumId'];
      if (typeof idVal === 'string') {
        this.albumId = idVal;
      }
      const nameVal: Object | undefined = params['albumName'];
      if (typeof nameVal === 'string' && nameVal.length > 0) {
        this.albumName = nameVal;
      }
      const artistVal: Object | undefined = params['artistName'];
      if (typeof artistVal === 'string') {
        this.artistName = artistVal;
      }
      const coverVal: Object | undefined = params['coverUrl'];
      if (typeof coverVal === 'string') {
        this.coverUrl = coverVal;
      }
    }
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async reload(): Promise<void> {
    // 用局部变量累积，最后**一次性**回写 @State。
    //
    // 为什么（codelinter `hp-arkui-use-local-var-to-replace-state-var`）：@State 每次赋值
    // 都会触发 UI 刷新。该规则统计的是**整个函数内**的赋值次数，超过 2 次即告警 ——
    // 所以不能只在末尾回写、却把早退分支里的 `this.status = ...` 留着（那样仍算多次）。
    // 这里把分支结果都写进局部变量，函数内每个 @State 只出现一次赋值。
    // CI 的 lint 差分曾据此在本页报出 5 处。
    let status: string = UiState.LOADING;
    let errorMsg: string = '';
    let tracks: MediaItem[] = [];
    let totalMs: number = 0;

    if (this.albumId.length === 0) {
      status = UiState.ERROR;
      errorMsg = '缺少专辑标识';
    } else {
      // ① 曲目列表
      const query: ItemsQueryOptions = new ItemsQueryOptions();
      query.parentId = this.albumId;
      query.startIndex = 0;
      query.limit = kTrackLimit;
      query.includeItemTypes = 'Audio';
      query.recursive = false;
      query.sortBy = 'ParentIndexNumber,IndexNumber,SortName';
      query.sortOrder = 'Ascending';
      query.enableUserData = false;

      const result: NativeResult =
        JellyfinNative.parseResult(await JellyfinNative.queryItems(query.toJson()));
      if (!result.ok || result.data === null) {
        status = UiState.ERROR;
        errorMsg = result.message.length > 0 ? result.message : '加载曲目失败';
      } else {
        try {
          tracks = MediaItem.fromArray(JsonUtil.extractItems(result.data));
          let sum: number = 0;
          for (let i = 0; i < tracks.length; i++) {
            sum += tracks[i].runTimeTicks;
          }
          // Ticks = 100ns 单位 → 毫秒
          totalMs = Math.floor(sum / 10000);

          // ② 专辑自身的元信息（封面 / 年份 / 艺术家）。
          // 单独取一次专辑条目：曲目里带的是音轨级信息，专辑封面与年份在专辑条目上。
          const albumRaw: string = await JellyfinNative.getItemDetail(this.albumId);
          const albumRes: NativeResult = JellyfinNative.parseResult(albumRaw);
          if (albumRes.ok && albumRes.data !== null) {
            const detail: MediaItem = MediaItem.fromJson(albumRes.data);
            if (detail.name.length > 0) {
              this.albumName = detail.displayTitle();
            }
            this.year = JsonUtil.getNumber(albumRes.data as ESObject, 'ProductionYear', 0);
            if (this.artistName.length === 0) {
              this.artistName = JsonUtil.getString(albumRes.data as ESObject, 'AlbumArtist', '');
            }
            if (this.coverUrl.length === 0) {
              this.coverUrl = detail.imageUrl(600, 'Primary');
            }
          }
          status = tracks.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
        } catch (err) {
          status = UiState.ERROR;
          errorMsg = `解析曲目失败：${(err as Error).message}`;
        }
      }
    }

    this.tracks = tracks;
    this.totalMs = totalMs;
    this.status = status;
    this.errorMsg = errorMsg;
  }

  /** 播单曲：把整张专辑与起始序号一起交给播放页，便于"下一首" */
  private playTrack(index: number): void {
    if (this.tracks.length === 0 || index < 0 || index >= this.tracks.length) {
      return;
    }
    this.playFrom(index);
  }

  private playAll(): void {
    if (this.tracks.length === 0) {
      return;
    }
    this.playFrom(0);
  }

  /**
   * 随机播放：随机选一个起始下标再交给播放页。
   *
   * 只改起始位置，不新增播放器能力 —— 播放页本来就是"拿着整张曲目表从某一首开始"，
   * 所以随机播放在这里等价于换一个 `startIndex`。点击后立刻进入播放页，
   * 不做任何动画（避免在点击与跳转之间插入延迟）。
   */
  private playRandom(): void {
    if (this.tracks.length === 0) {
      return;
    }
    const start: number = Math.floor(Math.random() * this.tracks.length);
    this.playFrom(start);
  }

  private playFrom(index: number): void {
    // 只把 id/标题/时长传过去，避免把整个 MediaItem 塞进路由参数
    const ids: string[] = [];
    const names: string[] = [];
    for (let i = 0; i < this.tracks.length; i++) {
      ids.push(this.tracks[i].id);
      names.push(this.tracks[i].displayTitle());
    }
    router.pushUrl({
      url: 'pages/MusicPlayerPage',
      params: {
        trackIds: ids,
        trackNames: names,
        startIndex: index,
        albumName: this.albumName,
        artistName: this.artistName,
        coverUrl: this.coverUrl
      }
    });
  }

  private subtitleLine(): string {
    const parts: string[] = [];
    if (this.artistName.length > 0) {
      parts.push(this.artistName);
    }
    if (this.year > 0) {
      parts.push(`${this.year}`);
    }
    parts.push(`${this.tracks.length} 首`);
    if (this.totalMs > 0) {
      parts.push(formatTicks(this.totalMs * 10000));
    }
    return parts.join(' · ');
  }

  // ─────────────────────────────────────────────────────────────
  // 视觉层
  //
  // 布局用「品牌色渐变 + 居中封面」的英雄区，而不是 DetailPage 那种
  // 「backdrop 图 + 渐变」：影视条目有宽幅剧照，音乐专辑通常没有。
  // 两条替代路（直接取 Backdrop、退回封面放大）都实测过且都不成立，
  // 结论写在 HeroSection 的注释里。
  // 底色只从 ThemeColors 取（不硬编码色值），否则换主题时会与其它页面不一致。
  // ─────────────────────────────────────────────────────────────

  /**
   * 英雄区背景。
   *
   * **刻意不用图片做全幅背景**，两条替代路都实测过且都不成立：
   *   1. 直接用 `Backdrop`：专辑通常没有 backdrop，而 Jellyfin 对缺失 backdrop 的条目
   *      会返回 HTTP 200 + **一张与条目无关的图**（实测该专辑 `BackdropImageTags` 为空，
   *      端点却返回一张城市街景 JPEG）—— 会串成别的画面。
   *   2. 退回用封面本身放大：背景与前景是同一张图，放大后文字互相叠加，
   *      看起来像渲染故障（实测截图可见标题在前后两层各出现一次）。
   *
   * 所以这里改用**纯主题色渐变**：从 `brandPrimaryLight`（品牌色的深色底）过渡到页面底色。
   * 好处是不依赖任何图片元数据、不可能串图，色调也与应用的品牌色一致。
   * （色值全部取自 ThemeColors，不硬编码，换主题时自动跟随。）
   */
  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：品牌深色 → 页面底色
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[this.colors().brandPrimaryLight, 0.0], [this.colors().pageBackground, 1.0]]
        })

      Column({ space: 14 }) {
        Blank().height(24)

        // 封面：带投影，让它从背景里"浮"出来
        JellyfinImage({
          url: this.coverUrl,
          imgWidth: 168,
          imgHeight: 168,
          cornerRadius: ThemeConstants.CARD_RADIUS,
          placeholderIcon: 'music'
        })
          .shadow({ radius: 24, color: this.colors().buttonShadow, offsetX: 0, offsetY: 10 })

        // 专辑名 + 副标题
        Column({ space: 6 }) {
          Text(this.albumName)
            .fontSize(ThemeConstants.TITLE_XLARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitleLine())
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .padding({ bottom: 18 })
    }
    .width('100%')
    .height(348)
  }

  /** 「播放全部」用主按钮规格（圆角/按下态/投影）与工程其余主操作保持一致 */
  @Builder
  ActionBar() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(ThemeConstants.ICON_MEDIUM)
            .fontColor([this.colors().onBrand])
          Text(`播放全部（${this.tracks.length}）`)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onBrand)
        }
        .justifyContent(FlexAlign.Center)
      }
      .height(48)
      .layoutWeight(1)
      .borderRadius(ThemeConstants.BUTTON_RADIUS)
      .backgroundColor(this.colors().brandPrimary)
      .shadow({ radius: 10, color: this.colors().buttonShadow, offsetX: 0, offsetY: 4 })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().brandPrimaryPressed)
        }
      })
      .onClick(() => {
        this.playAll();
      })

      // 随机播放：专辑较长时比"从头听"更常用。
      // 复用同一份曲目列表，只随机一个起始下标，不新增播放器能力。
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.shuffle'))
          .fontSize(ThemeConstants.ICON_MEDIUM)
          .fontColor([this.colors().textPrimary])
      }
      .width(48)
      .height(48)
      .backgroundColor(this.colors().surfacePressed)
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().chipBackgroundPressed)
        }
      })
      .onClick(() => {
        this.playRandom();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
  }

  /** 曲目行：按住时整行点亮，让"点哪里都能播"这件事在视觉上成立 */
  @Builder
  TrackRow(track: MediaItem, index: number) {
    Row({ space: 12 }) {
      // 序号等宽居中，位数不同的曲目也能对齐
      Text(`${index + 1}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textTertiary)
        .width(28)
        .textAlign(TextAlign.Center)
      Column({ space: 3 }) {
        Text(track.displayTitle())
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(formatTicks(track.runTimeTicks))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textTertiary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(ThemeConstants.ICON_SMALL)
        .fontColor([this.colors().textTertiary])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(ThemeConstants.CHIP_RADIUS)
    .stateStyles({
      pressed: {
        .backgroundColor(this.colors().surfacePressed)
      }
    })
    .onClick(() => {
      this.playTrack(index);
    })
  }

  /** 曲目区小标题：与工程其它分节标题（SectionHeader）的视觉层级一致 */
  @Builder
  TrackSectionHeader() {
    Row() {
      Text('曲目')
        .fontSize(ThemeConstants.TITLE_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
      Blank()
      Text(`${this.tracks.length} 首`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textTertiary)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
  }

  build() {
    Column() {
      if (this.status === UiState.LOADING) {
        PageHeader({ title: '', onBack: () => { router.back(); } })
        LoadingState({ hint: '正在加载曲目…' })
      } else if (this.status === UiState.ERROR) {
        PageHeader({ title: '', onBack: () => { router.back(); } })
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
          actionLabel: '重试',
          onAction: () => {
            this.reload();
          }
        })
      } else if (this.status === UiState.EMPTY) {
        PageHeader({ title: '', onBack: () => { router.back(); } })
        EmptyState({ message: '这张专辑没有曲目' })
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          // 滚动内容从页面顶部开始，让英雄区渐变顶到状态栏下方
          this.Content()

          // 返回按钮浮在最上层：背板是图片，标题放在背板上会与封面争夺注意力，
          // 所以标题留空、只保留返回。
          PageHeader({ title: '', transparent: true, onBack: () => { router.back(); } })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }

  @Builder
  Content() {
    List() {
      // 头部（封面 + 名称 + 副标题）与操作条作为列表的第一项，
      // 这样它们会随曲目一起滚动，长专辑时能腾出整屏看曲目。
      ListItem() {
        Column() {
          this.HeroSection()
          this.ActionBar()
          this.TrackSectionHeader()
        }
        .width('100%')
      }

      ForEach(this.tracks, (track: MediaItem, index: number) => {
        ListItem() {
          this.TrackRow(track, index)
        }
      }, (track: MediaItem, index: number) => `${track.id}_${index}`)

      ListItem() {
        // Blank 只能放在 Row/Column/Flex 下，ListItem 不接受，故包一层 Column 做列表尾留白
        Column() {
          Blank().height(24)
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // 不再用 divider：曲目行有按压态圆角，分隔线会穿过高亮块
  }
}

/**
 * 构造图片 URL。
 *
 * 为什么不直接写 `JellyfinNative.getImageUrl(...)` 当作 URL 用：
 * 那个桥接返回的是 JSON 信封 `{"ok":true,"data":{"url":"…"}}`，必须解析后取 `data.url`。
 * 直接把它当 URL 传下去会导致取图全部失败并显示占位图 —— 详情页演员头像此前就是栽在这里
 * （见 `DetailPage.personImageUrl` 与其注释）。这里复刻工程内既有的正确写法
 * （`MediaItem.imageUrl` / `LibraryModels.buildCoverUrl`：getImageUrl → parseResult → data.url）。
 */
function buildImageUrl(itemId: string, imageType: string, maxWidth: number, tag: string): string {
  if (itemId.length === 0) {
    return '';
  }
  const raw: string = JellyfinNative.getImageUrl(itemId, imageType, maxWidth, tag);
  const result: NativeResult = JellyfinNative.parseResult(raw);
  if (!result.ok || result.data === null) {
    return '';
  }
  return JsonUtil.getString(result.data as ESObject, 'url', '');
}
