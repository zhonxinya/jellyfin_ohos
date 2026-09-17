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

@Entry
@Component
struct LibraryPage {
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

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['parentId'];
      if (typeof idVal === 'string') {
        this.parentId = idVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
      const ct: Object | undefined = params['collectionType'];
      if (typeof ct === 'string') {
        this.collectionType = ct;
      }
    }
    this.setupTabs();
    this.reload();
  }

  private setupTabs(): void {
    if (this.collectionType === 'tvshows') {
      this.tabLabels = ['节目', '建议', '即将播出', '类型', '制片发行商', '剧集'];
    } else if (this.collectionType === 'movies') {
      this.tabLabels = ['电影', '建议', '我的最爱', '合集', '类型'];
    } else {
      this.tabLabels = ['全部', '我的最爱'];
    }
  }

  private colors(): ThemeColors {
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
        PageHeader({
          title: this.title,
          onBack: () => {
            router.back();
          }
        })

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
