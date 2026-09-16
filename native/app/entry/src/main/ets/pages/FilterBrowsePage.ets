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
import { MediaCollectionView } from '../components/MediaCollectionView';

@Entry
@Component
struct FilterBrowsePage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private title: string = '';
  @State private filterType: string = 'genre';
  @State private filterId: string = '';
  @State private parentId: string = '';
  @State private includeItemTypes: string = '';
  @State private items: MediaItem[] = [];
  @State private startIndex: number = 0;
  @State private hasMore: boolean = true;
  @State private loadingMore: boolean = false;
  @State private footerTriggered: boolean = false;
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const ft: Object | undefined = params['filterType'];
      if (typeof ft === 'string') {
        this.filterType = ft;
      }
      const fid: Object | undefined = params['filterId'];
      if (typeof fid === 'string') {
        this.filterId = fid;
      }
      const pid: Object | undefined = params['parentId'];
      if (typeof pid === 'string') {
        this.parentId = pid;
      }
      const types: Object | undefined = params['includeItemTypes'];
      if (typeof types === 'string') {
        this.includeItemTypes = types;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
    }
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private reload(): void {
    this.startIndex = 0;
    this.hasMore = true;
    this.items = [];
    this.footerTriggered = false;
    this.loadPage(false);
  }

  private async loadPage(more: boolean): Promise<void> {
    if (more) {
      if (!this.hasMore || this.loadingMore) {
        return;
      }
      this.loadingMore = true;
    } else {
      this.status = UiState.LOADING;
      this.errorMsg = '';
    }
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.parentId = this.parentId;
    query.startIndex = this.startIndex;
    query.limit = this.pageSize;
    query.includeItemTypes = this.includeItemTypes;
    query.sortBy = 'SortName';
    query.sortOrder = 'Ascending';
    if (this.filterType === 'studio') {
      query.studioIds = this.filterId;
    } else {
      query.genreIds = this.filterId;
    }
    const raw: string = await JellyfinNative.queryItems(query.toJson());
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
    this.hasMore = page.length >= this.pageSize;
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private openItem(item: MediaItem): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
  }

  build() {
    Column() {
      PageHeader({
        title: this.title,
        onBack: () => {
          router.back();
        }
      })

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
          viewMode: 'grid',
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
}
