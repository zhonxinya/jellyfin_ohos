import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { AsyncStateView } from '../components/AsyncStateView';
import { MediaCollectionView, MediaViewToggle } from '../components/MediaCollectionView';

@Entry
@Component
struct BrowsePage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private title: string = '';
  @State private browseType: string = '';
  @State private parentId: string = '';
  @State private items: MediaItem[] = [];
  @State private startIndex: number = 0;
  @State private hasMore: boolean = true;
  @State private loadingMore: boolean = false;
  @State private viewMode: string = 'grid';
  @State private footerTriggered: boolean = false;
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const typeVal: Object | undefined = params['browseType'];
      if (typeof typeVal === 'string') {
        this.browseType = typeVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
      const parentVal: Object | undefined = params['parentId'];
      if (typeof parentVal === 'string') {
        this.parentId = parentVal;
      }
    }
    if (this.title.length === 0) {
      this.title = '浏览';
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
      if (!this.hasMore || this.loadingMore || this.status === UiState.LOADING) {
        return;
      }
      this.loadingMore = true;
    } else {
      this.status = UiState.LOADING;
      this.errorMsg = '';
    }
    const raw: string = await JellyfinNative.getBrowseItems(this.browseType, this.startIndex, this.pageSize,
      this.parentId);
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

      Row() {
        Text(`${this.items.length} 项`)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
          .layoutWeight(1)
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
}
