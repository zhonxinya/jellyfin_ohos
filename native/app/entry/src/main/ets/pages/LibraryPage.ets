import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { PageHeader } from '../components/PageHeader';
import { AsyncStateView } from '../components/AsyncStateView';
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
      if (tabKey === 'favorites') {
        query.favoriteOnly = true;
      }
      if (tabKey === 'series') {
        query.includeItemTypes = 'Series';
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
    const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    if (more) {
      this.items = this.items.concat(page);
    } else {
      this.items = page;
    }
    this.startIndex = this.startIndex + page.length;
    this.hasMore = tabKey === 'genres' || tabKey === 'studios' ? false : page.length >= this.pageSize;
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
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
          Text(`${this.items.length} 项`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
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
          AsyncStateView({
            status: this.status,
            message: this.errorMsg,
            minHeight: 240,
            onRetry: () => {
              this.reload();
            }
          })
        } else {
          MediaCollectionView({
            items: $items,
            viewMode: this.viewMode,
            loadingMore: this.loadingMore,
            hasMore: this.hasMore,
            onItemTap: (item: MediaItem) => {
              this.openItem(item);
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
      .backgroundColor(this.colors().background)

    }
    .width('100%')
    .height('100%')
  }
}
