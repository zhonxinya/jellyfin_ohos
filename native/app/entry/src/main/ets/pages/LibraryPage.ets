import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { MediaItemMenu } from '../common/MediaItemMenu';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { MediaCollectionView, MediaViewToggle } from '../components/MediaCollectionView';
import { ChipButton } from '../components/ChipButton';
import { TextButton } from '../components/TextButton';

/**
 * 媒体库内容（全局唯一的媒体库浏览实现）。
 *
 * 两种用法：
 *  - **路由页**：`pages/LibraryPage` 是 main_pages 里注册的路由，由文件末尾那个只做转发的
 *    `LibraryPage` 壳承载（`embedded = false`，读路由参数、自己画顶栏）；
 *  - **页签内嵌**：底部「音乐」页签由 `MusicPage` 传 `embedded = true` 直接嵌它。
 *
 * 为什么拆成"壳 + 内容"而不是让 `@Entry` 结构体直接被嵌：`@Entry` 是页面级声明，
 * 页面自身要留在 main_pages 里给 `router.pushUrl` 用；把内容独立成普通组件后，
 * 两条路都只维护这一份实现（音乐库的四个视角、排序筛选、分页、长按菜单都在这里）。
 */
@Component
export struct LibraryContentView {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private title: string = '媒体库';
  @State private parentId: string = '';
  @State private collectionType: string = '';
  @State private libraryTabIndex: number = 0;
  @State private tabLabels: string[] = ['全部', '我的最爱'];
  @State private items: MediaItem[] = [];
  @State private startIndex: number = 0;
  @State private hasMore: boolean = true;
  @State private loadingMore: boolean = false;
  @State private viewMode: string = 'grid';
  @State private footerTriggered: boolean = false;
  @State private sortBy: string = 'SortName';
  @State private sortOrder: string = 'Ascending';
  /**
   * 筛选条件。
   *
   * 之前媒体库只有"排序"和一个收藏标签，无法回答"哪些还没看""只看 4K"这类最常见的问题；
   * 这些条件都对应 Jellyfin `/Items` 的查询参数（Filters / IsHD / Is4K / HasSubtitles）。
   */
  @State private playStateFilter: string = '';
  @State private resolutionFilter: string = '';
  @State private favoriteOnly: boolean = false;
  @State private subtitlesOnly: boolean = false;
  @State private showFilterPanel: boolean = false;
  /** 服务端返回的总条数（TotalRecordCount）；-1 表示服务端未返回 */
  @State private totalCount: number = -1;
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;
  /**
   * 嵌到底部页签时用（见 `MusicPage`）：参数改由属性传入，且不再画自己的顶栏。
   *
   * 与 `SettingsPage` 的 `embedded` 是同一套做法（外壳里直接 `SettingsPage({ embedded: true, ... })`）。
   * 复用而不是新写一份音乐列表：音乐库的四个视角（艺术家/专辑/曲目/我的最爱）、
   * 排序筛选、分页与长按菜单都在这里，重写一份必然漂移。
   */
  @Prop embedded: boolean = false;
  @Prop embeddedParentId: string = '';
  @Prop embeddedTitle: string = '';
  @Prop embeddedCollectionType: string = '';
  /**
   * 主题版本号，由外壳透传（路由页用法下不强求）。
   *
   * 内嵌页签**不会重建**，切换明暗主题时本页要能跟着重画 —— `colors()` 里读一下它，
   * 与 `HomePage`/`SettingsPage` 的做法一致。
   */
  @Prop themeTick: number = 0;

  aboutToAppear(): void {
    // 参数先落到局部变量、末尾一次性回写 @State：本函数里每个 @State 只赋值一次
    // （`@performance/hp-arkui-use-local-var-to-replace-state-var` 的计数口径是整个函数）
    let parentId: string = '';
    let title: string = '媒体库';
    let collectionType: string = '';
    if (this.embedded) {
      parentId = this.embeddedParentId;
      collectionType = this.embeddedCollectionType;
      if (this.embeddedTitle.length > 0) {
        title = this.embeddedTitle;
      }
    } else {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params !== undefined && params !== null) {
        const idVal: Object | undefined = params['parentId'];
        if (typeof idVal === 'string') {
          parentId = idVal;
        }
        const titleVal: Object | undefined = params['title'];
        if (typeof titleVal === 'string' && titleVal.length > 0) {
          title = titleVal;
        }
        const ct: Object | undefined = params['collectionType'];
        if (typeof ct === 'string') {
          collectionType = ct;
        }
      }
    }
    this.parentId = parentId;
    this.title = title;
    this.collectionType = collectionType;
    this.setupTabs();
    this.reload();
  }

  private setupTabs(): void {
    if (this.collectionType === 'tvshows') {
      this.tabLabels = ['节目', '建议', '即将播出', '类型', '制片发行商', '剧集'];
    } else if (this.collectionType === 'movies') {
      this.tabLabels = ['电影', '建议', '我的最爱', '合集', '类型'];
    } else if (this.collectionType === 'music') {
      // 音乐库的根内容**就是艺术家**（实测该库根目录返回 42 个 MusicArtist），
      // 所以「艺术家」放第一个且默认选中；再给出直接进专辑/曲目的视角，
      // 否则只有艺术家一列，用户想按专辑或按单曲找就得一级一级点下去。
      this.tabLabels = ['艺术家', '专辑', '曲目', '我的最爱'];
    } else {
      this.tabLabels = ['全部', '我的最爱'];
    }
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  private currentTabKey(): string {
    if (this.tabLabels.length === 0) {
      return 'all';
    }
    const label: string = this.tabLabels[this.libraryTabIndex];
    if (label === '节目' || label === '全部' || label === '电影') {
      return 'items';
    }
    if (label === '建议') {
      return 'suggestions';
    }
    if (label === '即将播出') {
      return 'upcoming';
    }
    if (label === '类型') {
      return 'genres';
    }
    if (label === '制片发行商') {
      return 'studios';
    }
    if (label === '剧集') {
      return 'series';
    }
    if (label === '我的最爱') {
      return 'favorites';
    }
    if (label === '合集') {
      return 'boxsets';
    }
    // 音乐库的三个视角（标签即视角，见 setupTabs）。
    // 不复用 'items'：那个 key 在下面的查询分支里只对 movies/tvshows 设类型，
    // 音乐三个标签必须各自映射到 MusicArtist / MusicAlbum / Audio。
    if (label === '艺术家') {
      return 'artists';
    }
    if (label === '专辑') {
      return 'albums';
    }
    if (label === '曲目') {
      return 'songs';
    }
    return 'items';
  }

  private reload(): void {
    this.startIndex = 0;
    this.hasMore = true;
    this.items = [];
    this.footerTriggered = false;
    this.loadPage(false);
  }

  /** 当前生效的筛选条件个数（用于按钮上显示「筛选 · N」） */
  private activeFilterCount(): number {
    let n: number = 0;
    if (this.playStateFilter.length > 0) {
      n++;
    }
    if (this.resolutionFilter.length > 0) {
      n++;
    }
    if (this.favoriteOnly) {
      n++;
    }
    if (this.subtitlesOnly) {
      n++;
    }
    return n;
  }

  private clearFilters(): void {
    this.playStateFilter = '';
    this.resolutionFilter = '';
    this.favoriteOnly = false;
    this.subtitlesOnly = false;
  }

  /** 把筛选条件写进查询（与排序、分页一起决定列表内容） */
  private applyFilters(query: ItemsQueryOptions, tabKey: string): void {
    // 「我的最爱」标签本身就等于收藏筛选，此时不再叠加筛选项里的收藏开关
    query.favoriteOnly = tabKey === 'favorites' ? true : this.favoriteOnly;
    if (this.playStateFilter.length > 0) {
      query.filters = this.playStateFilter;
    }
    if (this.resolutionFilter === 'hd') {
      query.isHd = true;
    } else if (this.resolutionFilter === '4k') {
      query.is4k = true;
    }
    query.hasSubtitles = this.subtitlesOnly;
    query.enableTotalRecordCount = true;
  }

  private async loadPage(more: boolean): Promise<void> {
    const tabKey: string = this.currentTabKey();
    if (more) {
      if (!this.hasMore || this.loadingMore || tabKey === 'suggestions') {
        return;
      }
      this.loadingMore = true;
    } else {
      this.status = UiState.LOADING;
      this.errorMsg = '';
    }

    let raw: string = '';
    if (tabKey === 'suggestions') {
      raw = await JellyfinNative.getSuggestions(this.parentId, 24);
    } else if (tabKey === 'upcoming') {
      raw = await JellyfinNative.getBrowseItems('upcoming', this.startIndex, this.pageSize, this.parentId);
    } else if (tabKey === 'genres') {
      raw = await JellyfinNative.getGenres(this.parentId, this.startIndex, 100);
    } else if (tabKey === 'studios') {
      raw = await JellyfinNative.getStudios(this.parentId, this.startIndex, 100);
    } else {
      const query: ItemsQueryOptions = new ItemsQueryOptions();
      query.parentId = this.parentId;
      query.startIndex = this.startIndex;
      query.limit = this.pageSize;
      query.sortBy = this.sortBy;
      query.sortOrder = this.sortOrder;
      this.applyFilters(query, tabKey);
      if (tabKey === 'series') {
        // 「剧集」= Episodes（Jellyfin Web 的语义）。
        // 这里原来也是 'Series'，于是与「节目」标签发出**完全相同**的请求，
        // 用户点「剧集」永远看不到分集列表，两个标签看起来都像坏了。
        query.includeItemTypes = 'Episode';
      } else if (tabKey === 'boxsets') {
        query.includeItemTypes = 'BoxSet';
      } else if (this.collectionType === 'movies') {
        query.includeItemTypes = 'Movie';
      } else if (this.collectionType === 'tvshows' && tabKey === 'items') {
        query.includeItemTypes = 'Series';
      } else if (this.collectionType === 'music') {
        // 音乐库三个视角各自只取一种类型：
        //   艺术家 tab -> MusicArtist（库根内容本身，但显式指定可避免混入文件夹）
        //   专辑   tab -> MusicAlbum（跨艺术家汇总所有专辑）
        //   曲目   tab -> Audio（跨专辑汇总所有单曲）
        // 不指定类型时服务端会返回混合结果（实测根目录是 MusicArtist + Folder），
        // 所以这里必须显式指定，否则「专辑」标签会混进艺术家。
        if (tabKey === 'artists') {
          query.includeItemTypes = 'MusicArtist';
          // 只取**库根下的艺术家**（= 专辑艺术家）。默认的 recursive 会把"曲目级"的伪艺术家
          // 也捞进来：服务端给每条曲目的 Artist 标签都建了 MusicArtist，标签不规范时名字就是
          // 歌名/专辑名（「九万字」「北京巷弄」…），点进去只有一张 `Unknown Album`。
          // 实测该库根 42 位艺术家，递归后变成 85 条 —— 用户看到的就是"艺术家页签里直接
          // 显示了一堆专辑"。专辑/曲目两个页签要跨艺术家汇总，仍然保持递归。
          query.recursive = false;
        } else if (tabKey === 'albums') {
          query.includeItemTypes = 'MusicAlbum';
        } else if (tabKey === 'songs') {
          query.includeItemTypes = 'Audio';
        }
      }
      raw = await JellyfinNative.queryItems(query.toJson());
    }

    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.loadingMore = false;
    this.footerTriggered = false;
    if (!result.ok) {
      if (!more) {
        this.status = UiState.ERROR;
        this.errorMsg = result.message.length > 0 ? result.message : '加载失败';
      }
      return;
    }
    try {
      const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      if (more) {
        this.items = this.items.concat(page);
      } else {
        this.items = page;
      }
      this.startIndex = this.startIndex + page.length;
      // 总数优先取服务端返回的 TotalRecordCount：
      // 原来用"本页条数 >= 每页条数"猜 hasMore，最后一页正好整除时会多请求一次，
      // 而界面上显示的"N 项"其实是"已加载条数"，用户看到 40 项会以为库里只有 40 项。
      this.totalCount = JsonUtil.getNumber(result.data as ESObject, 'TotalRecordCount', -1);
      if (tabKey === 'genres' || tabKey === 'studios') {
        this.hasMore = false;
      } else if (this.totalCount >= 0) {
        this.hasMore = this.items.length < this.totalCount;
      } else {
        this.hasMore = page.length >= this.pageSize;
      }
      this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    } catch (err) {
      // 解析异常也必须落到终态，否则界面永远停在"加载中"且分页标志位卡死
      this.loadingMore = false;
      if (!more) {
        this.status = UiState.ERROR;
        this.errorMsg = `加载失败：${(err as Error).message}`;
      }
    }
  }

  private openItem(item: MediaItem): void {
    const tabKey: string = this.currentTabKey();
    if (tabKey === 'genres') {
      router.pushUrl({
        url: 'pages/FilterBrowsePage',
        params: {
          filterType: 'genre',
          filterId: item.id,
          parentId: this.parentId,
          includeItemTypes: this.collectionType === 'tvshows' ? 'Series' : 'Movie',
          title: item.name
        }
      });
      return;
    }
    if (tabKey === 'studios') {
      router.pushUrl({
        url: 'pages/FilterBrowsePage',
        params: {
          filterType: 'studio',
          filterId: item.id,
          parentId: this.parentId,
          includeItemTypes: 'Movie',
          title: item.name
        }
      });
      return;
    }
    if (item.isFolder || item.type === 'CollectionFolder' || item.type === 'Folder') {
      router.pushUrl({
        url: 'pages/LibraryPage',
        params: {
          parentId: item.id,
          title: item.name,
          collectionType: item.collectionType
        }
      });
      return;
    }
    if (item.type === 'Person') {
      router.pushUrl({ url: 'pages/PersonPage', params: { personId: item.id } });
      return;
    }
    // 音乐条目各有专用页面：通用详情页没有音乐分支，进去只会拿不到任何有用信息
    // （它按 Movie/Series 那套渲染，曲目与专辑都没有对应控件）。
    if (item.type === 'MusicArtist') {
      router.pushUrl({
        url: 'pages/ArtistDetailPage',
        params: { artistId: item.id, artistName: item.displayTitle() }
      });
      return;
    }
    if (item.type === 'MusicAlbum') {
      router.pushUrl({
        url: 'pages/AlbumDetailPage',
        params: {
          albumId: item.id,
          albumName: item.displayTitle(),
          artistName: item.albumArtist
        }
      });
      return;
    }
    if (item.type === 'Audio') {
      // 单曲：从「曲目」标签直接点播，只播这一首（专辑连播在专辑页的「播放全部」）
      router.pushUrl({
        url: 'pages/MusicPlayerPage',
        params: {
          trackIds: [item.id],
          trackNames: [item.displayTitle()],
          startIndex: 0,
          artistName: item.albumArtist
        }
      });
      return;
    }
    router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
  }

  private applySort(field: string, order: string): void {
    this.sortBy = field;
    this.sortOrder = order;
    this.reload();
  }

  /**
   * 排序选择 —— 由手写全屏遮罩改为系统 ActionMenu。
   *
   * 参考项目对"单选项列表"一律用 `showActionMenu`（设置页主题选择、管理页行操作等都是这样），
   * 不再自己搭遮罩 + 卡片 + 按钮列表；颜色用品牌色/错误色的字面量（与参考项目一致）。
   */
  private openSortMenu(): void {
    const ctx = this.getUIContext();
    ctx.getPromptAction().showActionMenu({
      title: '排序方式',
      buttons: [
        { text: '名称 (A-Z)', color: '#007DFF' },
        { text: '名称 (Z-A)', color: '#007DFF' },
        { text: '最新添加', color: '#007DFF' },
        { text: '最早添加', color: '#007DFF' },
        { text: '首播时间（新→旧）', color: '#007DFF' },
        { text: '首播时间（旧→新）', color: '#007DFF' }
      ]
    }).then((result) => {
      const idx: number = result.index;
      if (idx === 0) {
        this.applySort('SortName', 'Ascending');
      } else if (idx === 1) {
        this.applySort('SortName', 'Descending');
      } else if (idx === 2) {
        this.applySort('DateCreated', 'Descending');
      } else if (idx === 3) {
        this.applySort('DateCreated', 'Ascending');
      } else if (idx === 4) {
        this.applySort('PremiereDate', 'Descending');
      } else if (idx === 5) {
        this.applySort('PremiereDate', 'Ascending');
      }
    }).catch(() => {
      // 用户取消菜单时不做处理
    });
  }

  /**
   * 筛选面板里的一行 chip。
   *
   * 用 `kind + value` 而不是回调参数来分发点击：本项目此前在播放页遇到过
   * `@Builder` 传函数类型参数导致转译产物语法错误（es2abc）的问题，
   * 统一沿用"参数化事件再分发"的写法，避免同类坑。
   */
  @Builder
  FilterChip(label: string, selected: boolean, kind: string, value: string) {
    ChipButton({
      label: label,
      selected: selected,
      onTap: () => {
        this.onFilterTap(kind, value);
      }
    })
  }

  /**
   * 筛选面板里的事件分发。
   *
   * 每点一下就**立即重新查询**（面板保持打开）：这样「共 N 项」会实时变化，
   * 用户能马上看到"只看未观看"到底筛掉了多少，而不是点完「完成」才知道结果为空。
   */
  private onFilterTap(kind: string, value: string): void {
    if (kind === 'state') {
      this.playStateFilter = this.playStateFilter === value ? '' : value;
    } else if (kind === 'res') {
      this.resolutionFilter = this.resolutionFilter === value ? '' : value;
    } else if (kind === 'fav') {
      this.favoriteOnly = !this.favoriteOnly;
    } else if (kind === 'sub') {
      this.subtitlesOnly = !this.subtitlesOnly;
    } else if (kind === 'reset') {
      this.clearFilters();
    } else {
      return;
    }
    this.reload();
  }

  /** 筛选面板：观看状态 / 分辨率 / 收藏 / 字幕 */
  @Builder
  FilterPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('筛选')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
        Blank()
        TextButton({
          label: '重置',
          onTap: () => {
            this.onFilterTap('reset', '');
          }
        })
      }
      .width('100%')

      this.FilterSectionTitle('观看状态')
      Row({ space: 8 }) {
        this.FilterChip('全部', this.playStateFilter.length === 0, 'state', '')
        this.FilterChip('未观看', this.playStateFilter === 'IsUnplayed', 'state', 'IsUnplayed')
        this.FilterChip('已观看', this.playStateFilter === 'IsPlayed', 'state', 'IsPlayed')
        this.FilterChip('播放中', this.playStateFilter === 'IsResumable', 'state', 'IsResumable')
      }
      .width('100%')

      this.FilterSectionTitle('清晰度')
      Row({ space: 8 }) {
        this.FilterChip('全部', this.resolutionFilter.length === 0, 'res', '')
        this.FilterChip('高清', this.resolutionFilter === 'hd', 'res', 'hd')
        this.FilterChip('4K', this.resolutionFilter === '4k', 'res', '4k')
      }
      .width('100%')

      this.FilterSectionTitle('其他')
      Row({ space: 8 }) {
        this.FilterChip('只看收藏', this.favoriteOnly, 'fav', '')
        this.FilterChip('只看带字幕', this.subtitlesOnly, 'sub', '')
      }
      .width('100%')

      Row({ space: 12 }) {
        Blank()
        TextButton({
          label: '完成',
          onTap: () => {
            // 筛选在点选时已生效，这里只负责收起面板
            this.showFilterPanel = false;
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FilterSectionTitle(text: string) {
    Text(text)
      .fontSize(ThemeConstants.LABEL_SMALL)
      .fontColor(this.colors().textTertiary)
      .margin({ top: 4 })
  }

  /** 分类切换 —— 参考项目用 FilterChips（34vp 圆角 chip，选中品牌实底）而非下划线 Tab */
  @Builder
  TabChips() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.tabLabels, (label: string, index: number) => {
          ChipButton({
            label: label,
            selected: this.libraryTabIndex === index,
            onTap: () => {
              this.libraryTabIndex = index;
              this.reload();
            }
          })
        }, (label: string, index: number) => `${label}_${index}`)
        Blank()
          .layoutWeight(1)
      }
      .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 12, bottom: 4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        if (!this.embedded) {
          PageHeader({
            title: this.title,
            onBack: () => {
              router.back();
            }
          })
        } else {
          // 内嵌页签下不画 PageHeader：外壳已经画了一条 56vp 的顶栏，再来一条就是两条。
          // 这里只留标题行（音乐页需要"这是音乐库"这一层上下文，四个视角的页签就在它下面）。
          Text(this.title)
            .fontSize(ThemeConstants.TITLE_XLARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .width('100%')
            .height(56)
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
            .backgroundColor(this.colors().cardBackground)
        }

        this.TabChips()

        Row() {
          Text(this.totalCount >= 0 ? `共 ${this.totalCount} 项` : `${this.items.length} 项`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          // 库内搜索：把当前库作为搜索范围带过去（此前只能全库搜，且搜索页没有范围概念）
          TextButton({
            label: '搜索',
            onTap: () => {
              router.pushUrl({
                url: 'pages/SearchPage',
                params: { parentId: this.parentId, scopeTitle: this.title }
              });
            }
          })
          // 筛选入口：带上生效条件个数，用户一眼能看出"列表为什么这么短"
          TextButton({
            label: this.activeFilterCount() > 0 ? `筛选 · ${this.activeFilterCount()}` : '筛选',
            onTap: () => {
              this.showFilterPanel = !this.showFilterPanel;
            }
          })
          TextButton({
            label: '排序',
            onTap: () => {
              this.openSortMenu();
            }
          })
           MediaViewToggle({
             mode: this.viewMode,
             onChange: (mode: string) => {
               this.viewMode = mode;
             }
           })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

        if (this.status !== UiState.SUCCESS) {
          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
            LoadingState()
          } else if (this.status === UiState.ERROR) {
            EmptyState({
              message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
              actionLabel: '重试',
              onAction: () => {
                this.reload();
              }
            })
          } else if (this.status === UiState.EMPTY) {
            EmptyState({ message: '暂无数据' })
          }
        } else {
          MediaCollectionView({
            items: $items,
            viewMode: this.viewMode,
            loadingMore: this.loadingMore,
            hasMore: this.hasMore,
            onItemTap: (item: MediaItem) => {
              this.openItem(item);
            },
            // 长按卡片：不经详情页即可播放/收藏/标记已看/加入播放列表
            onItemLongPress: (item: MediaItem) => {
              MediaItemMenu.show(this.getUIContext(), item, () => {
                this.items = MediaItemMenu.touch(this.items);
              });
            },
            onReachEnd: () => {
              if (!this.footerTriggered) {
                this.footerTriggered = true;
                this.loadPage(true);
              }
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      // 筛选面板：覆盖层挂在列表之上（列表本身不加模糊/遮罩，保持滚动位置可见）
      if (this.showFilterPanel) {
        Column() {
          Column() {
            this.FilterPanel()
          }
          .width('92%')
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(ThemeConstants.CARD_RADIUS)
          .shadow({ radius: 16, color: '#66000000', offsetX: 0, offsetY: 6 })
          .id('filterPanel')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().overlayControlStrong)
        // 刻意不给遮罩层挂 onClick：面板里的 chip 自身有点击处理，
        // 一旦上层遮罩也响应点击，某些 ArkUI 版本会把子组件的点击一并算到父级，
        // 表现为"点一下筛选条件面板就关了"。关闭统一走「完成」或再次点「筛选」。
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 路由页壳：`pages/LibraryPage`（HomePage 的媒体库卡片、搜索页等都用 `router.pushUrl` 进它）。
 *
 * 自身不持有任何状态，只把参数交给 `LibraryContentView` —— 页面级声明（`@Entry`）与
 * 内容实现分开后，底部「音乐」页签才能复用同一份内容（见 `MusicPage`）。
 */
@Entry
@Component
struct LibraryPage {
  build() {
    // @Entry 的 build 必须只有一个容器根节点：内容组件自己一个节点还不够，
    // 外面再套一层 Column（内容组件内部已经是 width/height 100% 的 Stack）
    Column() {
      LibraryContentView({ embedded: false })
    }
    .width('100%')
    .height('100%')
  }
}
