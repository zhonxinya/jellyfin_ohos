import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { MediaCollectionView } from '../components/MediaCollectionView';

@Entry
@Component
struct ContinueWatchingPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private startIndex: number = 0;
  @State private hasMore: boolean = true;
  @State private loadingMore: boolean = false;
  @State private footerTriggered: boolean = false;
  @State private viewMode: string = 'grid';
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;

  aboutToAppear(): void {
    this.loadPage(false);
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
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
      this.startIndex = 0;
      this.hasMore = true;
      this.items = [];
    }
    const raw: string = await JellyfinNative.getBrowseItems('resume', this.startIndex, this.pageSize);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.loadingMore = false;
    this.footerTriggered = false;
    if (!result.ok) {
      if (!more) {
        this.status = UiState.ERROR;
        this.errorMsg = result.message.length > 0 ? result.message : '加载继续观看失败';
      }
      return;
    }
    const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    this.items = more ? this.items.concat(page) : page;
    this.startIndex = this.startIndex + page.length;
    this.hasMore = page.length >= this.pageSize;
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private openItem(item: MediaItem): void {
    if (item.id.length > 0) {
      router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '继续观看',
        onBack: () => { router.back(); }
      })
      if (this.status !== UiState.SUCCESS) {
        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => { this.loadPage(false); }
          })
        } else if (this.status === UiState.EMPTY) {
          EmptyState({ message: '暂无继续观看内容' })
        }
      } else {
        MediaCollectionView({
          items: $items,
          viewMode: this.viewMode,
          loadingMore: this.loadingMore,
          hasMore: this.hasMore,
          onItemTap: (item: MediaItem) => { this.openItem(item); },
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
  }
}
