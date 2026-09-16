import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { AsyncStateView } from '../components/AsyncStateView';
import { MediaCollectionView } from '../components/MediaCollectionView';
import { TextButton } from '../components/TextButton';

@Entry
@Component
struct PlaylistsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private viewMode: string = 'grid';

  aboutToAppear(): void {
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.getPlaylists());
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载播放列表失败';
      return;
    }
    this.items = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private openItem(item: MediaItem): void {
    if (item.id.length > 0) {
      router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
    }
  }

  build() {
    Column() {
      PageHeader({ title: '播放列表', onBack: () => { router.back(); } })
      if (this.status !== UiState.SUCCESS) {
        AsyncStateView({
          status: this.status,
          message: this.errorMsg,
          emptyHint: '暂无播放列表',
          minHeight: 260,
          onRetry: () => { this.reload(); }
        })
      } else {
        Row() {
          Text(`${this.items.length} 个播放列表`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          // 刷新入口改用参考项目 TextButton（13fp Medium 品牌色 + 按下态），
          // 原来是 32vp/12fp 的临时小按钮
          TextButton({
            label: '刷新',
            onTap: () => {
              this.reload();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        MediaCollectionView({
          items: $items,
          viewMode: this.viewMode,
          loadingMore: false,
          hasMore: false,
          onItemTap: (item: MediaItem) => { this.openItem(item); },
          onReachEnd: () => {}
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().background)
  }
}
